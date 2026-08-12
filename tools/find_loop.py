#!/usr/bin/env python3
"""動画からシームレスにループする区間を探して切り出す。

    python3 tools/find_loop.py Assets/sample_dance3d.mp4 --min 4.0
    python3 tools/find_loop.py Assets/sample_dance3d.mp4 --min 4.0 --out Assets/sample_dance3d_loop.mp4

生成AIの動画は素で貼るとループの継ぎ目で必ず飛ぶ。開始と終了が同じポーズ・同じ位置に
戻るように撮って（生成して）おき、このスクリプトで **一番よく繋がるフレーム対** を
探して切り出す、という手順を想定している。

やっていること（Schödl らの Video Textures と同じ考え方）:
  - 動画を小さいグレースケールに落として全フレームをメモリに載せる
  - 候補 (i, j) = フレーム i..j-1 を再生して i に戻るループ。継ぎ目が見えないのは
    「本来 j-1 の次に来るはずのフレーム j」と「先頭 i」が一致するとき。
    つまり測るのは d(j, i) であって d(j-1, i) ではない
    （d(j-1, i) を最小化すると末尾と先頭が同じ絵になり、1フレーム重複して見える）
  - 静止画としての段差 d(j, i) だけでなく、その前後 d(j-1, i-1) / d(j+1, i+1) も足す。
    こうしないと「絵は似ているが動きの向きが逆」の点を掴んでしまう
  - 連続フレーム間の平均差分を基準（=これ以下なら人間には継ぎ目が見えない）として比を出す

背景が動く素材（カーテン・他人・露出のドリフト）はどう切ってもループしない。
その場合は素材を撮り直すのが早い。
"""

import argparse
import subprocess
import sys

import numpy as np

WIDTH, HEIGHT = 160, 90          # 比較用の縮小サイズ。これで十分な精度が出る


def probe_fps(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
         '-show_entries', 'stream=r_frame_rate', '-of', 'csv=p=0', path],
        capture_output=True, text=True, check=True).stdout.strip()
    num, _, den = out.partition('/')
    return float(num) / float(den or 1)


def load_frames(path):
    """全フレームを (n, HEIGHT, WIDTH) の float32 グレースケールで返す"""
    proc = subprocess.run(
        ['ffmpeg', '-v', 'error', '-i', path,
         '-vf', 'scale=%d:%d' % (WIDTH, HEIGHT), '-pix_fmt', 'gray',
         '-f', 'rawvideo', '-'],
        capture_output=True, check=True)
    buf = np.frombuffer(proc.stdout, dtype=np.uint8)
    n = buf.size // (WIDTH * HEIGHT)
    return buf[:n * WIDTH * HEIGHT].reshape(n, HEIGHT, WIDTH).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('video')
    ap.add_argument('--min', type=float, default=3.0, help='ループの最短の長さ（秒）')
    ap.add_argument('--max', type=float, default=0.0, help='ループの最長の長さ（秒・0で無制限）')
    ap.add_argument('--top', type=int, default=5, help='表示する候補数')
    ap.add_argument('--out', help='指定すると最良候補をこのパスへ書き出す')
    args = ap.parse_args()

    fps = probe_fps(args.video)
    f = load_frames(args.video)
    n = len(f)
    print('%s: %d frames @ %.3f fps (%.2f s)' % (args.video, n, fps, n / fps))

    # 連続フレーム間の平均差分 = 「継ぎ目が見えない」基準値
    consec = np.abs(f[1:] - f[:-1]).mean(axis=(1, 2))
    # 動きの少ない素材だと 0 になりうる（比を出すので 0 除算を避ける）
    baseline = max(float(np.median(consec)), 1e-3)
    print('median consecutive-frame diff = %.3f  (これ以下の段差なら見えない)' % baseline)

    lo = max(2, int(args.min * fps))
    hi = n - 1 if args.max <= 0 else min(n - 1, int(args.max * fps))
    if lo >= hi:
        sys.exit('--min が動画長を超えている')

    # d[a, b] = |frame a - frame b| の平均。全対を一気に作るとメモリを食うので行ごとに
    cands = []
    for i in range(1, n - lo - 2):
        jmax = min(n - 1, i + hi)
        js = np.arange(i + lo, jmax)
        if js.size == 0:
            continue
        # 継ぎ目そのもの（j-1 の次に来るはずの j と、実際に来る i の差）
        d0 = np.abs(f[js] - f[i]).mean(axis=(1, 2))
        # 動きの連続性（前後1フレームも合わせる）
        d1 = np.abs(f[js - 1] - f[i - 1]).mean(axis=(1, 2))
        d2 = np.abs(f[js + 1] - f[i + 1]).mean(axis=(1, 2))
        cost = d0 + 0.5 * (d1 + d2)
        k = int(np.argmin(cost))
        cands.append((float(cost[k]), float(d0[k]), i, int(js[k])))

    cands.sort()
    print('\n  cost   seam   ratio  start      end      length')
    for cost, d0, i, j in cands[:args.top]:
        print('  %5.2f  %5.2f  %5.2fx  %6.2fs  %6.2fs  %5.2fs  (frames %d..%d)'
              % (cost, d0, d0 / baseline, i / fps, j / fps, (j - i) / fps, i, j - 1))

    if not cands:
        sys.exit('候補なし')

    _, d0, i, j = cands[0]
    print('\n最良: frames %d..%d (%.3fs から %.3fs 分)。継ぎ目は連続フレーム差の %.2f 倍'
          % (i, j - 1, i / fps, (j - i) / fps, d0 / baseline))
    if d0 / baseline > 3.0:
        print('※ 3倍を超えている。素材側で開始/終了のポーズを揃えないとループは厳しい')

    if args.out:
        subprocess.run(
            ['ffmpeg', '-v', 'error', '-y', '-i', args.video,
             '-vf', 'trim=start_frame=%d:end_frame=%d,setpts=PTS-STARTPTS' % (i, j),
             '-an', '-c:v', 'libx264', '-crf', '20', '-pix_fmt', 'yuv420p',
             args.out], check=True)
        print('wrote %s' % args.out)


if __name__ == '__main__':
    main()
