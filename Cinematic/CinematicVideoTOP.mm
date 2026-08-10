// Cinematic TOP — iPhone Cinematicモード動画から、フレーム毎の深度(視差)マップ、または
// f値/ピントを差し替えて再レンダした映像を出す。デコード/レンダはワーカースレッドで行い
// cook をブロックしない(共有ヘルパ CinematicHelper が内部で latest を保持)。
//
// メタデータ(フォーカス深度・被写体スロット)は旧 Cinematic Data CHOP を統合し、
// Info CHOP チャンネル(focus_disparity / focus_strong / subjects / subject{i}/…)として出す。
// 取得は CNScript(ピクセルデコード不要)なので低コスト。Info CHOP をこのノードに
// 向けるだけで旧CHOPと同じデータが得られる。
#import <Foundation/Foundation.h>
#include <cmath>
#include <cstring>
#include <string>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "../common/NonCommercialLimit.h"
#include "../common/PyCallbacksBootstrap.h"
using namespace TD;

// Callbacks DAT 雛形(配置時に自動生成・ドックチップ接続)。
// Info CHOP トグル ON で隣にメタデータの Info CHOP を自動生成する(二重生成ガード付き)。
// このOPが出すのは全て数値(尺・フォーカス距離・被写体スロット)なので DAT ではなく CHOP。
static const char* PythonCallbacksDATStubs =
"# Cinematic Video TOP callbacks\n"
"#\n"
"# onInfoCHOP: 'Info CHOP' トグルを on にした瞬間に呼ばれる。\n"
"# 隣にメタデータ表示用の Info CHOP を自動生成する(既にあれば何もしない)。\n"
"def onInfoCHOP(op, enabled):\n"
"\tif not enabled:\n"
"\t\treturn\n"
"\tp = op.parent()\n"
"\tname = op.name + '_info'\n"
"\tif p.op(name):\n"
"\t\treturn\n"
"\tc = p.create(infoCHOP, name)\n"
"\tc.par.op = op.name\n"
"\tc.nodeX = op.nodeX + 200\n"
"\tc.nodeY = op.nodeY\n"
"\tc.viewer = True\n"
"\treturn\n";

extern "C" {
    void* cn_create(void); void cn_destroy(void*);
    void  cn_open(void*, const char*);
    const char* cn_status(void*);
    int   cn_depth(void*, double timeSec, int flip, int normalize);
    int   cn_latest_depth_info(void*, int* w, int* h, unsigned long long* serial);
    void  cn_copy_depth(void*, void* dst);
    int   cn_render(void*, double timeSec, float fNumber, float focusOverride, int flip);
    int   cn_latest_render_info(void*, int* w, int* h, unsigned long long* serial);
    void  cn_copy_render(void*, void* dst);
    const char* cn_meta(void*, double timeSec);
}

namespace {
struct Job { std::string file; int mode; double time; float fnum, focus; bool flip, norm; };

static constexpr int kMaxSub = 20;   // Info CHOP の被写体スロット上限(旧CHOPのスライダー上限)

// 旧 Cinematic Data CHOP と同じ被写体タイプコード
static int typeCode(const std::string& t) {
    if (t.find("Face") != std::string::npos) return 1;
    if (t.find("Head") != std::string::npos) return 2;
    if (t.find("Torso") != std::string::npos || t.find("Body") != std::string::npos) return 3;
    if (t.find("Cat") != std::string::npos) return 4;
    if (t.find("Dog") != std::string::npos) return 5;
    if (t.find("Ball") != std::string::npos) return 6;
    return 0;
}

// CNScript メタデータのスナップショット(worker が書き、cook がコピー)
struct Meta {
    float focus = 0, strong = 0;
    int count = 0;
    float sub[kMaxSub][7] = {};   // typecode,u,v,w,h,depth,trackid
};

class CinematicVideoTOP final : public TOP_CPlusPlusBase {
public:
    CinematicVideoTOP(const OP_NodeInfo* ni, TOP_Context* c) : myNode(ni), myContext(c) { myState = cn_create(); myThread = std::thread([this]{ worker(); }); }
    ~CinematicVideoTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join(); if (myState) cn_destroy(myState); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }
    void pulsePressed(const char* name, void*) override { if (!strcmp(name, "Cuepulse")) myCuePulse = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        // 配置後の cook で雛形入り Callbacks DAT を自動生成・ドック接続(成功するまでリトライ)
        if (!myBootstrapped) myBootstrapped = tdpycb::bootstrapCallbacksDAT(myNode, PythonCallbacksDATStubs);
        // Info CHOP トグル off→on で隣に Info CHOP を自動生成
        bool infoChop = in->getParInt("Infochop") != 0;
        if (infoChop && !myPrevInfoChop) {
            tdpycb::bootstrapCallbacksDAT(myNode, PythonCallbacksDATStubs);   // 消されていたら再生成
            tdpycb::firePythonCallback(myNode, "onInfoCHOP", true);
        }
        myPrevInfoChop = infoChop;
        if (!myState) return;
        Job j;
        j.file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        j.mode = (int)in->getParInt("Mode");            // 0=Depth 1=Rendered
        j.fnum = (float)in->getParDouble("Fnumber");
        j.focus = (float)in->getParDouble("Focus");     // 0=script準拠, else 上書き
        j.flip = in->getParInt("Flip") != 0;
        j.norm = in->getParInt("Normalize") != 0;
        myMax = std::clamp((int)in->getParInt("Maxsubjects"), 1, kMaxSub);
        if (j.file != myFile) { myFile = j.file; myTime = 0; if (!j.file.empty()) cn_open(myState, j.file.c_str()); }

        // status(status|duration|fps|error)
        std::string st, err; double dur = 0, fps = 0;
        { const char* s = cn_status(myState); if (s) { std::string all(s); free((void*)s);
            size_t a=all.find('|'), b=all.find('|',a+1), c=all.rfind('|');
            if(a!=std::string::npos&&b!=std::string::npos&&c!=std::string::npos){
                st=all.substr(0,a); dur=atof(all.substr(a+1,b-a-1).c_str());
                fps=atof(all.substr(b+1,c-b-1).c_str()); err=all.substr(c+1);} } }
        myStatus = st; myErr = err; myDur = dur;

        // 再生位置(秒)。Movie File In と同じくタイムライン駆動で、
        // deltaMS ぶんだけ進める(TDのタイムラインを止めれば止まる)
        bool play = in->getParInt("Play") != 0;
        double cuePoint = in->getParDouble("Cuepoint");
        if (myCuePulse.exchange(false)) myTime = cuePoint;
        if (in->getParInt("Cue") != 0) {
            myTime = cuePoint;                       // Cue On の間はキュー点で保持
        } else if (play) {
            const OP_TimeInfo* ti = in->getTimeInfo();
            myTime += (ti ? ti->deltaMS / 1000.0 : 0.0) * in->getParDouble("Speed");
            if (dur > 0) {
                if (in->getParInt("Loop") != 0) { myTime = std::fmod(myTime, dur); if (myTime < 0) myTime += dur; }
                else myTime = std::clamp(myTime, 0.0, dur);
            }
        } else {
            // Play が Off のときは Position(0..1)で手動スクラブ(Movie File In の Index と同じ役割)
            myTime = std::clamp((double)in->getParDouble("Position"), 0.0, 1.0) * (dur > 0 ? dur : 0);
        }
        // ソースのフレーム境界へ量子化する。しないと同じ絵を何度もデコードし直すことになる
        j.time = (fps > 0) ? std::round(myTime * fps) / fps : myTime;
        myPlaying = play && in->getParInt("Cue") == 0;

        // ジョブ投入(ready時・変化時)
        char b[256]; snprintf(b,sizeof b,"%d|%.5f|%.3f|%.4f|%d|%d",j.mode,j.time,j.fnum,j.focus,j.flip?1:0,j.norm?1:0);
        std::string sig = j.file + "|" + b;
        if (st == "ready" && sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) { myJob = j; myPending = true; mySubmit++; l.unlock(); myCond.notify_one(); }
            else mySig.clear();
        }

        // メタデータの最新スナップショットを Info CHOP 用にコピー
        { std::lock_guard<std::mutex> l(myMutex); myMetaSnap = myMeta; }

        // 最新結果をアップロード。Both は 0=Rendered / 1=Depth の2色バッファに出す
        // (SDK上、色バッファごとに解像度もピクセル形式も別でよい。1以降は Render Select TOP で取る)
        myNCScaled = false;
        bool ok = false;
        if (j.mode == 2) { ok  = uploadPlane(out, false, 0);
                           ok |= uploadPlane(out, true,  1); }
        else               ok  = uploadPlane(out, j.mode == 0, 0);
        if (ok) myFrames++;
    }

    // 1面ぶんのアップロード。depth=true で視差マップ、false で再レンダ映像
    bool uploadPlane(TOP_Output* out, bool depth, uint32_t bufIndex) {
        int lw=0, lh=0; unsigned long long serial=0;
        bool has = depth ? cn_latest_depth_info(myState,&lw,&lh,&serial)
                         : cn_latest_render_info(myState,&lw,&lh,&serial);
        if (!has || lw <= 0 || lh <= 0) return false;
        const OP_PixelFormat pf = depth ? OP_PixelFormat::Mono32Float
                                        : OP_PixelFormat::RGBA16Float;
        const size_t bytes = (size_t)lw * lh * (depth ? sizeof(float) : 4 * sizeof(uint16_t));

        if ((uint32_t)lw > tdnc::kMaxDim || (uint32_t)lh > tdnc::kMaxDim) {
            // NC の 1280x1280 上限を超える。超えたまま渡すと TD がクランプ後の幅で
            // バッファを読み絵が崩れるので、いったん自前バッファへ出して縮小する。
            // (上限内のときは下の直接コピー経路のままで、余計なコピーはしない)
            std::vector<uint8_t> tmp(bytes);
            if (depth) cn_copy_depth(myState, tmp.data());
            else       cn_copy_render(myState, tmp.data());
            uint32_t cw = (uint32_t)lw, ch = (uint32_t)lh;
            if (tdnc::fit(tmp, cw, ch, pf)) myNCScaled = true;
            TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.colorBufferIndex=bufIndex;
            ui.textureDesc.width=cw; ui.textureDesc.height=ch; ui.textureDesc.pixelFormat=pf;
            auto buf = myContext->createOutputBuffer(tmp.size(), TOP_BufferFlags::None, nullptr); if(!buf) return false;
            memcpy(buf->data, tmp.data(), tmp.size());
            out->uploadBuffer(&buf, ui, nullptr);
        } else {
            TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.colorBufferIndex=bufIndex;
            ui.textureDesc.width=lw; ui.textureDesc.height=lh; ui.textureDesc.pixelFormat=pf;
            auto buf = myContext->createOutputBuffer(bytes, TOP_BufferFlags::None, nullptr); if(!buf) return false;
            if (depth) cn_copy_depth(myState, buf->data);
            else       cn_copy_render(myState, buf->data);
            out->uploadBuffer(&buf, ui, nullptr);
        }
        myUploaded = serial;
        return true;
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "Cinematic";
        { OP_StringParameter p("File"); p.label = "Cinematic Video (iPhone)"; p.page = PAGE; m->appendFile(p); }
        { OP_StringParameter p("Mode"); p.label = "Mode"; p.page = PAGE;
          const char* n[] = {"Depth","Rendered","Both"};
          const char* l[] = {"Depth (disparity map)","Rendered (change focus/aperture)",
                             "Both (0 = rendered, 1 = depth)"};
          std::vector<const char*> nv(n,n+3), lv(l,l+3); p.defaultValue="Rendered"; m->appendMenu(p,3,nv.data(),lv.data()); }
        // 再生系(Movie File In と同じ考え方: Play On で自動再生、Off のとき Position で手動スクラブ)
        { OP_NumericParameter p("Play"); p.label="Play"; p.page=PAGE; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Speed"); p.label="Speed"; p.page=PAGE; p.defaultValues[0]=1; p.minSliders[0]=-2; p.maxSliders[0]=2; m->appendFloat(p); }
        { OP_NumericParameter p("Loop"); p.label="Loop"; p.page=PAGE; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Cue"); p.label="Cue"; p.page=PAGE; p.defaultValues[0]=0; m->appendToggle(p); }
        { OP_NumericParameter p("Cuepoint"); p.label="Cue Point (sec)"; p.page=PAGE; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=60; m->appendFloat(p); }
        { OP_NumericParameter p("Cuepulse"); p.label="Cue Pulse"; p.page=PAGE; m->appendPulse(p); }
        { OP_NumericParameter p("Position"); p.label="Position (0..1, when Play is off)"; p.page=PAGE; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=1; p.minValues[0]=0; p.maxValues[0]=1; p.clampMins[0]=p.clampMaxes[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Fnumber"); p.label="Aperture (f-number)"; p.page=PAGE; p.defaultValues[0]=4.0; p.minSliders[0]=2; p.maxSliders[0]=16; m->appendFloat(p); }
        { OP_NumericParameter p("Focus"); p.label="Focus Disparity Override (0=use script)"; p.page=PAGE; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=1; m->appendFloat(p); }
        { OP_NumericParameter p("Normalize"); p.label="Normalize Depth (0..1)"; p.page=PAGE; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Flip"); p.label="Flip Vertically"; p.page=PAGE; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Maxsubjects"); p.label="Max Subjects (Info CHOP)"; p.page=PAGE; p.defaultValues[0]=10; p.minSliders[0]=1; p.maxSliders[0]=20; p.minValues[0]=1; p.maxValues[0]=kMaxSub; p.clampMins[0]=p.clampMaxes[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Infochop"); p.label="Info CHOP"; p.page=PAGE; p.defaultValues[0]=0; m->appendToggle(p); }
    }

    // Info CHOP: 診断 + 旧 Cinematic Data CHOP のメタデータチャンネル
    static constexpr int kFixedChans = 10;  // executes,submits,frames,ready,duration,position,playing,focus_disparity,focus_strong,subjects
    int32_t getNumInfoCHOPChans(void*) override { return kFixedChans + myMax * 8; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        if (i < kFixedChans) {
            int ready = (myStatus == "ready") ? 1 : 0;
            const char* n[] = {"executes","submits","frames","ready","duration","position","playing",
                               "focus_disparity","focus_strong","subjects"};
            float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myFrames.load(),(float)ready,
                         (float)myDur, (float)myTime, myPlaying ? 1.f : 0.f,
                         myMetaSnap.focus, myMetaSnap.strong, (float)myMetaSnap.count};
            c->name->setString(n[i]); c->value = v[i];
            return;
        }
        int k = i - kFixedChans, slot = k / 8, f = k % 8;
        const char* fn[] = {"valid","type","u","v","w","h","depth","trackid"};
        char b[32]; snprintf(b, sizeof b, "subject%d/%s", slot + 1, fn[f]);
        c->name->setString(b);
        if (slot >= myMetaSnap.count) { c->value = 0; return; }
        c->value = (f == 0) ? 1.0f : myMetaSnap.sub[slot][f - 1];
    }
    std::atomic<bool> myNCScaled{false};   // NC上限で縮小したか（警告表示用）
    void getWarningString(OP_String* s, void*) override {
        if (myStatus == "error" && !myErr.empty()) s->setString(("Cinematic: " + myErr).c_str());
        else if (myNCScaled) s->setString(tdnc::kWarning);
    }

private:
    void worker() {
        while (true) {
            Job j;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l, [this]{ return myQuit || myPending; }); if (myQuit) return; j = myJob; myPending = false; myBusy = true; }
            if (j.mode != 1) cn_depth(myState, j.time, j.flip?1:0, j.norm?1:0);
            if (j.mode != 0) cn_render(myState, j.time, j.fnum, j.focus, j.flip?1:0);
            fetchMeta(j.time);   // 同一worker上でCNScriptメタも更新(ヘルパ呼び出しを直列化)
            { std::lock_guard<std::mutex> l(myMutex); myBusy = false; }
        }
    }

    // worker: cn_meta の JSON をパースして Meta を更新(旧 Cinematic Data CHOP のロジック)
    void fetchMeta(double t) {
        const char* j = cn_meta(myState, t);
        if (!j) return;
        std::string js(j); free((void*)j);
        Meta meta;
        @autoreleasepool {
            NSData* d = [NSData dataWithBytes:js.data() length:js.size()];
            NSDictionary* m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (![m isKindOfClass:[NSDictionary class]]) return;
            meta.focus = [m[@"focus"] floatValue];
            meta.strong = [m[@"strong"] floatValue];
            NSArray* subs = m[@"subjects"];
            int n = [subs isKindOfClass:[NSArray class]] ? (int)subs.count : 0;
            meta.count = std::min(n, kMaxSub);
            for (int i = 0; i < meta.count; i++) {
                NSDictionary* s = subs[i];
                std::string ty = s[@"type"] ? [[s[@"type"] description] UTF8String] : "";
                meta.sub[i][0] = (float)typeCode(ty);
                meta.sub[i][1] = [s[@"x"] floatValue];
                meta.sub[i][2] = [s[@"y"] floatValue];
                meta.sub[i][3] = [s[@"w"] floatValue];
                meta.sub[i][4] = [s[@"h"] floatValue];
                meta.sub[i][5] = [s[@"depth"] floatValue];
                meta.sub[i][6] = [s[@"id"] floatValue];
            }
        }
        std::lock_guard<std::mutex> l(myMutex);
        myMeta = meta;
    }

    const OP_NodeInfo* myNode = nullptr;   // Python コールバック用
    bool myBootstrapped = false, myPrevInfoChop = false;
    TOP_Context* myContext; void* myState = nullptr;
    std::thread myThread; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit=false, myPending=false, myBusy=false;
    Job myJob; std::string myFile, mySig, myStatus, myErr; unsigned long long myUploaded=0;
    double myDur = 0; int myMax = 10;
    double myTime = 0;                 // 再生位置(秒)。Play On のとき deltaMS ぶん進む
    bool myPlaying = false;
    std::atomic<bool> myCuePulse{false};
    Meta myMeta, myMetaSnap;   // myMeta=worker書き込み(要mutex) / myMetaSnap=cookスレッド専用
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myFrames{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Cinematicvideo");
    i->customOPInfo.opLabel->setString("Cinematic Video");
    i->customOPInfo.opIcon->setString("CNV");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/Cinematic/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
    i->customOPInfo.pythonCallbacksDAT = PythonCallbacksDATStubs;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new CinematicVideoTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<CinematicVideoTOP*>(i); }
}
