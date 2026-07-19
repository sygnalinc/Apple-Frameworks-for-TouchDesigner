// Photogrammetry SOP — TouchDesigner カスタムオペレータ(macOS / RealityKit Object Capture)
//
// **写真フォルダから3Dメッシュを再構成**する(PhotogrammetrySession・macOS 12+)。
// 物体を一周撮った写真20枚以上を Image Folder に置き、Start をパルス →
// 数分の処理後、生成メッシュを SOP ジオメトリとして出力+OBJファイル保存。
//
// 出力形式は Output File の拡張子で決まる(.obj 推奨。SOP表示は .obj のみ)。
// 処理は分単位のじっくり系。進捗は Info CHOP の progress と警告文で見る。
//
// 実装: セッションは Swift ヘルパ dylib(ph_)。完了検知後、OBJ をワーカーで
// パースして SOP に出す(v/f のみ。テクスチャは OBJ+MTL を外部ツールで)。

#import <Foundation/Foundation.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "SOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

extern "C" {
void* ph_create(void);
void ph_start(void* h, const char* folder, const char* output, int32_t detail);
void ph_poll(void* h, char* buf, int32_t n);
void ph_cancel(void* h);
void ph_destroy(void* h);
}

namespace {

struct Mesh
{
    std::vector<Position> points;
    std::vector<TexCoord> uvs;        // points と同数(vt が無ければ空)
    std::vector<int32_t> triangles;   // 3 indices per tri
    uint64_t serial = 0;
};

class PhotogrammetrySOP final : public SOP_CPlusPlusBase
{
public:
    explicit PhotogrammetrySOP(const OP_NodeInfo*)
    {
        mySession = ph_create();
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~PhotogrammetrySOP() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
        if (mySession)
            ph_destroy(mySession);
    }

    void getGeneralInfo(SOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
        ginfo->directToGPU = false;
    }

    void executeVBO(SOP_VBOOutput*, const OP_Inputs*, void*) override {}

    void execute(SOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        std::string folder, outfile;
        if (const char* f = inputs->getParString("Imagefolder"))
            folder = f;
        if (const char* o = inputs->getParString("Outputfile"))
            outfile = o;
        const char* d = inputs->getParString("Detail");
        const int detail = (strcmp(d, "preview") == 0) ? 0
                         : (strcmp(d, "reduced") == 0) ? 1
                         : (strcmp(d, "full") == 0)    ? 3 : 2;

        if (myStartRequested && mySession && !folder.empty() && !outfile.empty()) {
            myStartRequested = false;
            myLoadedObj = false;
            ph_start(mySession, folder.c_str(), outfile.c_str(), detail);
        } else {
            myStartRequested = false;
        }
        if (myCancelRequested && mySession) {
            myCancelRequested = false;
            ph_cancel(mySession);
        }

        // 状態ポーリング。完了したら OBJ パースをワーカーへ
        char buf[1024] = {0};
        if (mySession)
            ph_poll(mySession, buf, sizeof(buf));
        myStatusJson = buf;
        myProgress = (float)extractNum(buf, "progress");
        myTexturePath = extractStr(buf, "texture");
        const bool done = strstr(buf, "\"done\":true") != nullptr;
        if (done && !myLoadedObj && !outfile.empty() &&
            outfile.size() > 4 && outfile.substr(outfile.size() - 4) == ".obj") {
            myLoadedObj = true;
            std::lock_guard<std::mutex> lock(myMutex);
            myPendingObj = outfile;
            myHasPending = true;
            myCond.notify_one();
        }

        // 最新メッシュを出力
        Mesh mesh;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            mesh = myMesh;
        }
        if (!mesh.points.empty()) {
            output->addPoints(mesh.points.data(), (int32_t)mesh.points.size());
            // 一括の setTexCoords は先頭UVが全点に入る不具合があるため(実測)、
            // TD付属サンプルと同じ per-point の setTexCoord を使う
            if (mesh.uvs.size() == mesh.points.size())
                for (int32_t i = 0; i < (int32_t)mesh.uvs.size(); i++)
                    output->setTexCoord(&mesh.uvs[i], 1, i);
            if (!mesh.triangles.empty())
                output->addTriangles(mesh.triangles.data(),
                                     (int32_t)(mesh.triangles.size() / 3));
        }
        myPointCount = (int)mesh.points.size();
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Imagefolder");
            p.label = "Image Folder";
            p.page = "Photogrammetry";
            manager->appendFolder(p);
        }
        {
            OP_StringParameter p("Outputfile");
            p.label = "Output File";
            p.page = "Photogrammetry";
            p.defaultValue = "scan.obj";
            manager->appendFile(p);
        }
        {
            OP_StringParameter p("Detail");
            p.label = "Detail";
            p.page = "Photogrammetry";
            p.defaultValue = "medium";
            const char* names[] = {"preview", "reduced", "medium", "full"};
            const char* labels[] = {"Preview (Fast)", "Reduced", "Medium", "Full (Slow)"};
            manager->appendMenu(p, 4, names, labels);
        }
        {
            OP_NumericParameter p("Start");
            p.label = "Start Reconstruction";
            p.page = "Photogrammetry";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Cancel");
            p.label = "Cancel";
            p.page = "Photogrammetry";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Start") == 0)
            myStartRequested = true;
        else if (strcmp(name, "Cancel") == 0)
            myCancelRequested = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "progress", "points"};
        float values[3] = {(float)myExecCount, myProgress.load(), (float)myPointCount};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    bool getInfoDATSize(OP_InfoDATSize* infoSize, void*) override
    {
        infoSize->rows = 2;
        infoSize->cols = 2;
        infoSize->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t index, int32_t, OP_InfoDATEntries* entries, void*) override
    {
        if (index == 0) {
            entries->values[0]->setString("texture");
            entries->values[1]->setString(myTexturePath.c_str());
        } else {
            entries->values[0]->setString("status");
            entries->values[1]->setString(myStatusJson.c_str());
        }
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if (!mySession) {
            warning->setString("Photogrammetry requires macOS 12+");
            return;
        }
        // status/error をそのまま警告として見せる
        std::string s = myStatusJson;
        if (!s.empty() && s != "{}")
            warning->setString(s.c_str());
    }

private:
    static double extractNum(const char* json, const char* key)
    {
        std::string pat = std::string("\"") + key + "\":";
        const char* p = strstr(json, pat.c_str());
        return p ? atof(p + pat.size()) : 0.0;
    }

    // JSONSerialization は "/" を "\/" にエスケープするので戻す
    static std::string extractStr(const char* json, const char* key)
    {
        std::string pat = std::string("\"") + key + "\":\"";
        const char* p = strstr(json, pat.c_str());
        if (!p)
            return "";
        p += pat.size();
        const char* e = strchr(p, '"');
        std::string s = e ? std::string(p, e - p) : "";
        std::string out;
        out.reserve(s.size());
        for (size_t i = 0; i < s.size(); i++) {
            if (s[i] == '\\' && i + 1 < s.size() && s[i + 1] == '/') {
                out += '/';
                i++;
            } else {
                out += s[i];
            }
        }
        return out;
    }

    void workerLoop()
    {
        while (true) {
            std::string path;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                path = std::move(myPendingObj);
                myHasPending = false;
            }
            Mesh mesh;
            parseObj(path, mesh);
            {
                std::lock_guard<std::mutex> lock(myMutex);
                mesh.serial = ++mySerial;
                myMesh = std::move(mesh);
            }
        }
    }

    // OBJ パーサ(v / vt / f。f の多角形は扇状に三角形分割)。
    // OBJ は位置とUVが別インデックスなので、(v,vt) の組ごとに TD の点を分割して
    // 各点に1つのUVが付くようにする(UVシーム対応)
    static void parseObj(const std::string& path, Mesh& mesh)
    {
        FILE* fp = fopen(path.c_str(), "r");
        if (!fp)
            return;
        char line[1024];
        std::vector<float> rawV;    // x,y,z の連続
        std::vector<float> rawVT;   // u,v の連続
        std::unordered_map<uint64_t, int32_t> vertMap;   // (v<<32|vt) → 点番号
        std::vector<int32_t> faceIdx;
        bool hasVT = false;

        while (fgets(line, sizeof(line), fp)) {
            if (line[0] == 'v' && line[1] == ' ') {
                float x, y, z;
                if (sscanf(line + 2, "%f %f %f", &x, &y, &z) == 3) {
                    rawV.push_back(x);
                    rawV.push_back(y);
                    rawV.push_back(z);
                }
            } else if (line[0] == 'v' && line[1] == 't') {
                float u, v;
                if (sscanf(line + 2, "%f %f", &u, &v) == 2) {
                    rawVT.push_back(u);
                    rawVT.push_back(v);
                    hasVT = true;
                }
            } else if (line[0] == 'f' && line[1] == ' ') {
                faceIdx.clear();
                const char* p = line + 2;
                const long nv = (long)(rawV.size() / 3);
                const long nt = (long)(rawVT.size() / 2);
                while (*p) {
                    while (*p == ' ')
                        p++;
                    if (!*p || *p == '\n' || *p == '\r')
                        break;
                    char* end = nullptr;
                    long v = strtol(p, &end, 10);
                    long t = 0;
                    if (end && *end == '/') {
                        const char* q = end + 1;
                        if (*q != '/')
                            t = strtol(q, nullptr, 10);
                    }
                    if (v != 0) {
                        const long vi = v > 0 ? v - 1 : nv + v;
                        const long ti = t > 0 ? t - 1 : (t < 0 ? nt + t : -1);
                        const uint64_t key =
                            ((uint64_t)(uint32_t)vi << 32) | (uint32_t)(ti + 1);
                        auto it = vertMap.find(key);
                        int32_t idx;
                        if (it != vertMap.end()) {
                            idx = it->second;
                        } else {
                            idx = (int32_t)mesh.points.size();
                            mesh.points.emplace_back(rawV[vi * 3], rawV[vi * 3 + 1],
                                                     rawV[vi * 3 + 2]);
                            TexCoord tc;
                            tc.u = (ti >= 0) ? rawVT[ti * 2] : 0.0f;
                            tc.v = (ti >= 0) ? rawVT[ti * 2 + 1] : 0.0f;
                            tc.w = 0.0f;
                            mesh.uvs.push_back(tc);
                            vertMap.emplace(key, idx);
                        }
                        faceIdx.push_back(idx);
                    }
                    while (*p && *p != ' ' && *p != '\n')
                        p++;
                }
                for (size_t i = 2; i < faceIdx.size(); i++) {
                    mesh.triangles.push_back(faceIdx[0]);
                    mesh.triangles.push_back(faceIdx[i - 1]);
                    mesh.triangles.push_back(faceIdx[i]);
                }
            }
        }
        fclose(fp);
        if (!hasVT)
            mesh.uvs.clear();
    }

    void* mySession = nullptr;
    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myStartRequested = false;
    bool myCancelRequested = false;
    bool myLoadedObj = false;
    std::string myPendingObj, myStatusJson, myTexturePath;
    Mesh myMesh;
    uint64_t mySerial = 0;

    std::atomic<int> myExecCount{0}, myPointCount{0};
    std::atomic<float> myProgress{0.0f};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillSOPPluginInfo(SOP_PluginInfo* info)
{
    if (!info->setAPIVersion(SOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Realitykitcapture");
    info->customOPInfo.opLabel->setString("RealityKit Capture");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("RKC");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT SOP_CPlusPlusBase*
CreateSOPInstance(const OP_NodeInfo* info)
{
    return new PhotogrammetrySOP(info);
}

DLLEXPORT void
DestroySOPInstance(SOP_CPlusPlusBase* instance)
{
    delete static_cast<PhotogrammetrySOP*>(instance);
}

}   // extern "C"
