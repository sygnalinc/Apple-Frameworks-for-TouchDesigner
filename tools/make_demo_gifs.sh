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
set -e
cd "$(dirname "${(%):-%N}")/.."

SRC=demo_capture
OUT=docs/demo
mkdir -p "$OUT"

filter() {   # 幅 fps 強さ
    print -r -- "fps=${2},scale=${1}:-1:flags=lanczos,hqdn3d=${3},split[a][b];[a]palettegen=max_colors=64:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle"
}

# name | source | start(s) | duration(s) | 幅 | fps | hqdn3d
CLIPS=(
    "visionpose|VisionPose.mp4|0|4.0|480|12|8:8:14:14"
    "visionhand|VisionHand.mp4|0|4.0|480|12|8:8:14:14"
    "visionface|VisionFace.mp4|0|4.0|480|12|8:8:14:14"      # 4.0s 以降は元動画が終わり輪郭だけになる
    "visiontext|VisionText.mp4|3.4|3.0|480|12|8:8:14:14"    # 認識枠が出るのは 3.4s から
    # 人混みの街路はほぼ全画素が毎フレーム変わるので、幅と fps を落として強めに除去する
    "coreml-yolo|CoreMLDAT(yolo).mp4|0|4.0|440|10|12:12:20:20"
)

for c in "${CLIPS[@]}"; do
    parts=("${(@s:|:)c}")
    name="$parts[1]"; file="$parts[2]"; ss="$parts[3]"; dur="$parts[4]"
    ffmpeg -v error -y -ss "$ss" -t "$dur" -i "$SRC/$file" \
        -vf "$(filter "$parts[5]" "$parts[6]" "$parts[7]")" -loop 0 "$OUT/$name.gif"
    printf "%-14s %5s KB  (%ss from %ss of %s)\n" \
        "$name.gif" "$(( $(stat -f%z "$OUT/$name.gif") / 1024 ))" "$dur" "$ss" "$file"
done
