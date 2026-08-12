// VisionPose3D（VNDetectHumanBodyPose3DRequest）の推定を、正解データ無しで評価する。
//
//   clang -fobjc-arc -framework Foundation -framework Vision -framework CoreGraphics \
//         -framework AppKit -o /tmp/pose3d_eval tools/pose3d_eval.m
//   ffmpeg -v error -i Assets/sample_pose3d.mp4 -vf fps=6 /tmp/ev/%04d.png
//   /tmp/pose3d_eval /tmp/ev/*.png
//
// ■ 使えなかった指標（先に潰した）
//   「骨の長さは剛体なら一定のはず」→ **Vision は固定プロポーションの人体モデルを使っており、
//   骨の長さは別の動画・別の人物でも完全に同一の定数**（上腕 0.3165 / 前腕 0.2475 /
//   腿 0.4705 / 脛 0.4849 m）。角度だけを推定しているので、長さの一定性は
//   推定品質と無関係で指標にならない。同じ理由で「人物の体格を測る」用途にも使えない。
//   pointInImage との再投影誤差も 0（3Dから導出された値なので独立でない）。
//
// ■ ここで測るもの: **2D姿勢推定（VNDetectHumanBodyPoseRequest）との食い違い**
//   2D検出器は3Dとは別のモデルなので、独立した比較対象になる。3Dの関節を画像に投影して
//   2D検出の位置と比べ、ズレの大きい関節＝3D推定が苦手にしている関節、と読む。
//   （どちらが正しいかは決まらないが、両者が一致していれば少なくとも画像とは整合している）
//
//   ズレは px ではなく **人物の大きさ（2D検出のバウンディングボックス高）に対する %** で出す。
//   px のままだと 1920 幅の映像が 1280 幅より不利になり、被写体が小さく写っているだけで
//   数字が良く見えてしまう。%なら解像度も画角も違うクリップ同士を並べられる。

#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <AppKit/AppKit.h>
#import <simd/simd.h>

typedef struct { const char* name; int idx3d; VNHumanBodyPoseObservationJointName j2d; } Pair;

enum { ROOT, SPINE, CSHOULDER, CHEAD, THEAD, LSH, LEL, LWR, RSH, REL, RWR,
       LHIP, LKNEE, LANK, RHIP, RKNEE, RANK, NJOINTS };


// ---- 幾何的に「正解が分かる」量を角度で見る -------------------------------
// 正解データセットが無くても、こういう不変量なら検証できる:
//   torso_pitch  : 体幹が鉛直から何度傾いているか。お辞儀・スクワットで 0→90 度付近まで動くはず
//   head_tilt    : 体幹に対する頭の角度。首を傾げた分だけ動き、体幹の傾きには追従しないはず
//   arm_elev_L/R : 腕が水平から何度か。T-pose なら 0 度・左右差 0 になるはず
//   knee_flex_L/R: 膝の曲げ角（180=まっすぐ）
static double angleBetween(simd_float3 a, simd_float3 b)
{
    const double la = simd_length(a), lb = simd_length(b);
    if (la < 1e-9 || lb < 1e-9) return NAN;
    double c = simd_dot(a, b) / (la * lb);
    c = fmax(-1.0, fmin(1.0, c));
    return acos(c) * 180.0 / M_PI;
}

int main(int argc, const char** argv)
{
    @autoreleasepool {
        const VNHumanBodyPose3DObservationJointName jn[NJOINTS] = {
            VNHumanBodyPose3DObservationJointNameRoot, VNHumanBodyPose3DObservationJointNameSpine,
            VNHumanBodyPose3DObservationJointNameCenterShoulder,
            VNHumanBodyPose3DObservationJointNameCenterHead, VNHumanBodyPose3DObservationJointNameTopHead,
            VNHumanBodyPose3DObservationJointNameLeftShoulder, VNHumanBodyPose3DObservationJointNameLeftElbow,
            VNHumanBodyPose3DObservationJointNameLeftWrist,
            VNHumanBodyPose3DObservationJointNameRightShoulder, VNHumanBodyPose3DObservationJointNameRightElbow,
            VNHumanBodyPose3DObservationJointNameRightWrist,
            VNHumanBodyPose3DObservationJointNameLeftHip, VNHumanBodyPose3DObservationJointNameLeftKnee,
            VNHumanBodyPose3DObservationJointNameLeftAnkle,
            VNHumanBodyPose3DObservationJointNameRightHip, VNHumanBodyPose3DObservationJointNameRightKnee,
            VNHumanBodyPose3DObservationJointNameRightAnkle };

        const Pair pairs[] = {
            {"neck",       CSHOULDER, VNHumanBodyPoseObservationJointNameNeck},
            {"shoulder_L", LSH,  VNHumanBodyPoseObservationJointNameLeftShoulder},
            {"shoulder_R", RSH,  VNHumanBodyPoseObservationJointNameRightShoulder},
            {"elbow_L",    LEL,  VNHumanBodyPoseObservationJointNameLeftElbow},
            {"elbow_R",    REL,  VNHumanBodyPoseObservationJointNameRightElbow},
            {"wrist_L",    LWR,  VNHumanBodyPoseObservationJointNameLeftWrist},
            {"wrist_R",    RWR,  VNHumanBodyPoseObservationJointNameRightWrist},
            {"hip_L",      LHIP, VNHumanBodyPoseObservationJointNameLeftHip},
            {"hip_R",      RHIP, VNHumanBodyPoseObservationJointNameRightHip},
            {"knee_L",     LKNEE,VNHumanBodyPoseObservationJointNameLeftKnee},
            {"knee_R",     RKNEE,VNHumanBodyPoseObservationJointNameRightKnee},
            {"ankle_L",    LANK, VNHumanBodyPoseObservationJointNameLeftAnkle},
            {"ankle_R",    RANK, VNHumanBodyPoseObservationJointNameRightAnkle},
        };
        const int np = (int)(sizeof(pairs) / sizeof(pairs[0]));

        double sum[32] = {0}, worst[32] = {0}; int cnt[32] = {0};
        double *pitch = (double*)calloc(argc, sizeof(double));
        double *htilt = (double*)calloc(argc, sizeof(double));
        double *armL  = (double*)calloc(argc, sizeof(double));
        double *armR  = (double*)calloc(argc, sizeof(double));
        double *kneeL = (double*)calloc(argc, sizeof(double));
        double *kneeR = (double*)calloc(argc, sizeof(double));
        int nang = 0;
        int frames = 0, both = 0;
        size_t W = 0, H = 0;

        for (int a = 1; a < argc; a++) {
            @autoreleasepool {
                NSImage* img = [[NSImage alloc] initWithContentsOfFile:
                                [NSString stringWithUTF8String:argv[a]]];
                CGImageRef cg = [img CGImageForProposedRect:nil context:nil hints:nil];
                if (!cg) continue;
                frames++;
                W = CGImageGetWidth(cg); H = CGImageGetHeight(cg);

                VNDetectHumanBodyPose3DRequest* r3 = [[VNDetectHumanBodyPose3DRequest alloc] init];
                VNDetectHumanBodyPoseRequest*   r2 = [[VNDetectHumanBodyPoseRequest alloc] init];
                VNImageRequestHandler* h = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
                [h performRequests:@[r3, r2] error:nil];
                VNHumanBodyPose3DObservation* o3 = r3.results.firstObject;
                VNHumanBodyPoseObservation*   o2 = r2.results.firstObject;
                if (!o3 || !o2) continue;
                both++;

                {
                    simd_float3 P[NJOINTS]; BOOL okall = YES;
                    for (int j = 0; j < NJOINTS; j++) {
                        VNHumanBodyRecognizedPoint3D* q = [o3 recognizedPointForJointName:jn[j] error:nil];
                        if (!q) { okall = NO; break; }
                        const simd_float4x4 m = q.position;
                        // **カメラ空間で測る**。model 空間の +Y は体幹軸に沿っているらしく、
                        // そのままだと torso_pitch が定義上ほぼ 0 になってお辞儀を検出できない
                        // （スクワットで range 10.9 度しか出ずに気づいた）。
                        // cameraOriginMatrix を掛けると Y がカメラの上方向になる
                        const simd_float4 cp = simd_mul(o3.cameraOriginMatrix,
                            simd_make_float4(m.columns[3].x, m.columns[3].y, m.columns[3].z, 1));
                        P[j] = simd_make_float3(cp.x, cp.y, cp.z);
                    }
                    if (okall) {
                        const simd_float3 up = simd_make_float3(0, 1, 0);
                        const simd_float3 torso = P[CSHOULDER] - P[ROOT];
                        pitch[nang] = angleBetween(torso, up);
                        htilt[nang] = angleBetween(P[THEAD] - P[CHEAD], torso);
                        // 腕が水平から何度か（+上 / -下）
                        const simd_float3 aL = P[LWR] - P[LSH], aR = P[RWR] - P[RSH];
                        armL[nang] = 90.0 - angleBetween(aL, up);
                        armR[nang] = 90.0 - angleBetween(aR, up);
                        kneeL[nang] = angleBetween(P[LHIP] - P[LKNEE], P[LANK] - P[LKNEE]);
                        kneeR[nang] = angleBetween(P[RHIP] - P[RKNEE], P[RANK] - P[RKNEE]);
                        nang++;
                    }
                }
                // 人物の大きさ = 2D検出点の縦の広がり（px）。VNHumanBodyPoseObservation には
                // boundingBox が無いので自前で求める。前傾すると多少縮むが 0 にはならないし、
                // 3D側の推定に依存しないので比較の物差しとして使える
                double ylo = 1e9, yhi = -1e9;
                for (int k = 0; k < np; k++) {
                    VNRecognizedPoint* q = [o2 recognizedPointForJointName:pairs[k].j2d error:nil];
                    if (!q || q.confidence < 0.5f) continue;
                    const double y = q.y * (double)H;
                    if (y < ylo) ylo = y;
                    if (y > yhi) yhi = y;
                }
                const double scale = yhi - ylo;
                if (scale < 20.0) continue;   // 検出点が少なすぎて尺度にならない

                for (int k = 0; k < np; k++) {
                    VNPoint* p3 = [o3 pointInImageForJointName:jn[pairs[k].idx3d] error:nil];
                    VNRecognizedPoint* p2 = [o2 recognizedPointForJointName:pairs[k].j2d error:nil];
                    if (!p3 || !p2 || p2.confidence < 0.5f)
                        continue;
                    // 正規化座標のままだと縦横でスケールが違うのでピクセルに直す
                    const double dx = (p3.x - p2.x) * (double)W;
                    const double dy = (p3.y - p2.y) * (double)H;
                    const double d = 100.0 * sqrt(dx * dx + dy * dy) / scale;
                    sum[k] += d; cnt[k]++;
                    if (d > worst[k]) worst[k] = d;
                }
            }
        }

        printf("frames=%d  3D+2D both detected=%d (%.1f%%)  image=%zux%zu\n\n",
               frames, both, frames ? 100.0 * both / frames : 0.0, W, H);
        if (!both) return 1;

        printf("3D関節を画像に投影した位置と、2D姿勢推定の位置とのズレ（人物の身長比 %%）\n");
        printf("  %-12s %8s %8s %6s\n", "joint", "mean", "worst", "n");
        double tot = 0; int totn = 0;
        for (int k = 0; k < np; k++) {
            if (!cnt[k]) { printf("  %-12s %8s\n", pairs[k].name, "-"); continue; }
            printf("  %-12s %8.2f %8.2f %6d\n", pairs[k].name, sum[k] / cnt[k], worst[k], cnt[k]);
            tot += sum[k]; totn += cnt[k];
        }
        if (nang) {
            printf("\n幾何的な不変量（正解データ無しで検証できる量）\n");
            printf("  %-14s %8s %8s %8s\n", "measure", "min", "max", "range");
            const char* an[6] = {"torso_pitch", "head_tilt", "arm_elev_L", "arm_elev_R",
                                 "knee_flex_L", "knee_flex_R"};
            double* ap[6] = {pitch, htilt, armL, armR, kneeL, kneeR};
            for (int m = 0; m < 6; m++) {
                double lo = 1e9, hi = -1e9;
                for (int i = 0; i < nang; i++) {
                    if (isnan(ap[m][i])) continue;
                    if (ap[m][i] < lo) lo = ap[m][i];
                    if (ap[m][i] > hi) hi = ap[m][i];
                }
                printf("  %-14s %8.1f %8.1f %8.1f\n", an[m], lo, hi, hi - lo);
            }
            printf("  ※ 度。お辞儀/スクワットなら torso_pitch の range が大きくなる。\n");
            printf("     T-pose を含むクリップなら arm_elev の L/R が 0 付近で一致するはず\n");
        }
        free(pitch); free(htilt); free(armL); free(armR); free(kneeL); free(kneeR);

        printf("\n全関節平均 = %.2f %%（人物の身長比）← クリップ比較用の総合スコア\n",
               totn ? tot / totn : 0.0);
    }
    return 0;
}
