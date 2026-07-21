#!/usr/bin/env python3
# IEEE OUI (MA-L/MA-M/MA-S) から NetworkDiscovery/oui.txt を生成する。
# 使い方: 3ファイルをDLして本スクリプトを回す。
#   curl -sSo /tmp/oui.csv   https://standards-oui.ieee.org/oui/oui.csv
#   curl -sSo /tmp/mam.csv   https://standards-oui.ieee.org/oui28/mam.csv
#   curl -sSo /tmp/oui36.csv https://standards-oui.ieee.org/oui36/oui36.csv
#   python3 tools/gen_oui.py /tmp/oui.csv /tmp/mam.csv /tmp/oui36.csv NetworkDiscovery/oui.txt
# 出力は "prefixhex(小文字)\tベンダー名"。prefixは 6/7/9 桁(24/28/36bit)。
import csv, re, sys
srcs = sys.argv[1:4]
dst = sys.argv[4] if len(sys.argv) > 4 else 'NetworkDiscovery/oui.txt'
out = {}
for fn in srcs:
    with open(fn, newline='', encoding='utf-8', errors='replace') as f:
        r = csv.reader(f); next(r, None)
        for row in r:
            if len(row) < 3: continue
            asn = row[1].strip().lower(); org = re.sub(r'\s+', ' ', row[2].strip().strip('"').strip())
            if asn and org: out[asn] = org
with open(dst, 'w', encoding='utf-8') as f:
    for p in sorted(out): f.write('%s\t%s\n' % (p, out[p]))
print('wrote %s: %d entries' % (dst, len(out)))
