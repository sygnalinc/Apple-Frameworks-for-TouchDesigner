#!/bin/zsh
# eval/ に置いた動画を VisionPose3D の評価にかける。
#
#   ./tools/eval_video.sh                 # eval/ の全動画
#   ./tools/eval_video.sh eval/foo.mp4    # 指定した動画だけ
#   FPS=6 MAXF=300 ./tools/eval_video.sh  # サンプリング間隔と上限を変える
#
# 1フレームあたり 3D+2D の2モデルを回すので約0.2秒かかる。既定は 3fps・150フレーム上限
# （＝1本あたり30秒前後）。細かく見たいときだけ FPS を上げる。
set -e
cd "$(dirname "${(%):-%N}")/.."

FPS=${FPS:-3}
MAXF=${MAXF:-150}
BIN=/tmp/pose3d_eval

# ビルド。`| head` でパイプを閉じると clang が SIGPIPE で死んでリンクまで届かないので繋がない
clang -fobjc-arc -framework Foundation -framework Vision -framework CoreGraphics \
      -framework AppKit -o "$BIN" tools/pose3d_eval.m

if [[ $# -gt 0 ]]; then
    files=("$@")
else
    files=(eval/*.mp4(N) eval/*.mov(N) eval/*.MOV(N) eval/*.webm(N) eval/*.m4v(N))
fi

for f in $files; do
    [[ -e "$f" ]] || continue
    print -r -- "\n================================================================"
    print -r -- "$(basename "$f")"
    print -r -- "================================================================"
    dir=$(mktemp -d /tmp/ev.XXXXXX)
    ffmpeg -v error -i "$f" -vf "fps=${FPS}" -frames:v "$MAXF" "$dir/%04d.png"
    "$BIN" "$dir"/*.png
    rm -rf "$dir"
done
