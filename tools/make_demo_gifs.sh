#!/bin/zsh
# demo_capture/ の画面収録(1280x720/60fps)を README 用の GIF に変換する。
#
#   ./tools/make_demo_gifs.sh
#
# 出力は docs/demo/*.gif。GIF はフレーム間差分でしか縮まないので、
#   - hqdn3d で軽くノイズを落として「変化しない画素」を増やす（これが一番効く）
#   - 480px 幅 / 12fps / 64色 / ディザ無し
#   - 尺は数秒に切る（元動画が終わって背景だけになる区間は落とす）
# の4点で 1〜2MB に収める。GitHub の README は mp4 を埋め込めないので GIF にする。
#
# 細い線のオーバーレイ（顔のランドマーク等）は 480px / 64色 だと潰れて背景も
# 縞になるので、その clip だけ幅と色数を上げて尺で埋め合わせる。
set -e
cd "$(dirname "${(%):-%N}")/.."

SRC=demo_capture
OUT=docs/demo
mkdir -p "$OUT"

filter() {   # 幅 fps hqdn3d 色数
    print -r -- "fps=${2},scale=${1}:-1:flags=lanczos,hqdn3d=${3},split[a][b];[a]palettegen=max_colors=${4}:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle"
}

# name | source | start(s) | duration(s) | 幅 | fps | hqdn3d | 色数
CLIPS=(
    "visionpose|VisionPose.mp4|0|4.0|480|12|8:8:14:14|64"
    "visionhand|VisionHand.mp4|0|4.0|480|12|8:8:14:14|64"
    # 顔のランドマークは線が細いので幅と色数を上げ、そのぶん尺を詰める
    "visionface|VisionFace.mp4|0|3.2|560|12|8:8:14:14|128"
    "visiontext|VisionText.mp4|3.4|3.0|480|12|8:8:14:14|64"    # 認識枠が出るのは 3.4s から
    "visionanimalpose|VisionAnimalPose.mp4|2.6|3.0|480|12|8:8:14:14|64"  # 2.6s まで骨格だけで元動画が出ない
    # 人混みの街路はほぼ全画素が毎フレーム変わるので、幅と fps を落として強めに除去する
    "coreml-yolo|CoreMLDAT(yolo).mp4|0|4.0|440|10|12:12:20:20|64"
)

for c in "${CLIPS[@]}"; do
    parts=("${(@s:|:)c}")
    name="$parts[1]"; file="$parts[2]"; ss="$parts[3]"; dur="$parts[4]"
    ffmpeg -v error -y -ss "$ss" -t "$dur" -i "$SRC/$file" \
        -vf "$(filter "$parts[5]" "$parts[6]" "$parts[7]" "$parts[8]")" -loop 0 "$OUT/$name.gif"
    printf "%-14s %5s KB  (%ss from %ss of %s)\n" \
        "$name.gif" "$(( $(stat -f%z "$OUT/$name.gif") / 1024 ))" "$dur" "$ss" "$file"
done
