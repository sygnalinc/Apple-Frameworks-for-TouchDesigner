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

#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <AppKit/AppKit.h>
#import <simd/simd.h>

typedef struct { const char* name; int idx3d; VNHumanBodyPoseObservationJointName j2d; } Pair;

enum { ROOT, SPINE, CSHOULDER, CHEAD, THEAD, LSH, LEL, LWR, RSH, REL, RWR,
       LHIP, LKNEE, LANK, RHIP, RKNEE, RANK, NJOINTS };

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

                for (int k = 0; k < np; k++) {
                    VNPoint* p3 = [o3 pointInImageForJointName:jn[pairs[k].idx3d] error:nil];
                    VNRecognizedPoint* p2 = [o2 recognizedPointForJointName:pairs[k].j2d error:nil];
                    if (!p3 || !p2 || p2.confidence < 0.5f)
                        continue;
                    // 正規化座標のままだと縦横でスケールが違うのでピクセルに直す
                    const double dx = (p3.x - p2.x) * (double)W;
                    const double dy = (p3.y - p2.y) * (double)H;
                    const double d = sqrt(dx * dx + dy * dy);
                    sum[k] += d; cnt[k]++;
                    if (d > worst[k]) worst[k] = d;
                }
            }
        }

        printf("frames=%d  3D+2D both detected=%d (%.1f%%)  image=%zux%zu\n\n",
               frames, both, frames ? 100.0 * both / frames : 0.0, W, H);
        if (!both) return 1;

        printf("3D関節を画像に投影した位置と、2D姿勢推定の位置とのズレ（px）\n");
        printf("  %-12s %8s %8s %6s\n", "joint", "mean", "worst", "n");
        double tot = 0; int totn = 0;
        for (int k = 0; k < np; k++) {
            if (!cnt[k]) { printf("  %-12s %8s\n", pairs[k].name, "-"); continue; }
            printf("  %-12s %8.1f %8.1f %6d\n", pairs[k].name, sum[k] / cnt[k], worst[k], cnt[k]);
            tot += sum[k]; totn += cnt[k];
        }
        printf("\n全関節平均 = %.1f px  ← クリップ比較用の総合スコア（小さいほど画像と整合）\n",
               totn ? tot / totn : 0.0);
    }
    return 0;
}
