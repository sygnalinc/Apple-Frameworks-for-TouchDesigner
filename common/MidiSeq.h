#pragma once
// Standard MIDI File を読んで秒に展開する。AU Instrument と CoreMIDI In で共有する。
// **ヘッダに実装があるが、それぞれ別バンドルなので重複シンボルにはならない**
// (Multipeer In/Out と同じ型)。ObjC の型は使っていないので純 C++ として使える。
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>

// Standard MIDI File を秒に展開したもの。format 0/1・テンポマップ・ランニングステータス対応
struct MidiEvent { double t; uint8_t s, d1, d2; };

struct MidiSeq {
    std::vector<MidiEvent> ev;
    double duration = 0;
    double bpm = 120;          // ファイル先頭のテンポ。TD テンポ同期の分母に使う
    std::string path, err;

    static uint32_t be32(const uint8_t* p) { return (p[0]<<24)|(p[1]<<16)|(p[2]<<8)|p[3]; }

    bool load(const std::string& file)
    {
        ev.clear(); duration = 0; bpm = 120; err.clear(); path = file;
        if (file.empty()) return false;
        FILE* f = fopen(file.c_str(), "rb");
        if (!f) { err = "cannot open MIDI file"; return false; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        std::vector<uint8_t> d((size_t)std::max(0L, n));
        if (n <= 0 || fread(d.data(), 1, (size_t)n, f) != (size_t)n) { fclose(f); err = "cannot read MIDI file"; return false; }
        fclose(f);
        if (d.size() < 14 || memcmp(d.data(), "MThd", 4)) { err = "not a Standard MIDI File"; return false; }

        const int ntrk = (d[10]<<8)|d[11];
        const int div  = (int16_t)((d[12]<<8)|d[13]);
        // (tick, 順序, status, d1, d2)。tempo は同時刻の音より先に処理する
        struct Raw { uint64_t tick; int ord; uint8_t s, d1, d2; uint32_t tempo; };
        std::vector<Raw> raw;
        size_t p = 8 + be32(&d[4]);
        for (int t = 0; t < ntrk && p + 8 <= d.size(); t++) {
            if (memcmp(&d[p], "MTrk", 4)) break;
            const size_t len = be32(&d[p+4]);
            size_t q = p + 8, end = std::min(d.size(), q + len);
            uint64_t tick = 0; uint8_t run = 0;
            while (q < end) {
                uint64_t v = 0;                       // 可変長デルタ
                while (q < end) { const uint8_t b = d[q++]; v = (v<<7)|(b&0x7f); if (!(b&0x80)) break; }
                tick += v;
                if (q >= end) break;
                uint8_t st = d[q];
                if (st == 0xff) {
                    q++; const uint8_t ty = d[q++];
                    uint64_t l = 0;
                    while (q < end) { const uint8_t b = d[q++]; l = (l<<7)|(b&0x7f); if (!(b&0x80)) break; }
                    if (ty == 0x51 && l == 3 && q + 3 <= end)
                        raw.push_back({tick, -1, 0, 0, 0, (uint32_t)((d[q]<<16)|(d[q+1]<<8)|d[q+2])});
                    q += l;
                } else if (st == 0xf0 || st == 0xf7) {
                    q++; uint64_t l = 0;
                    while (q < end) { const uint8_t b = d[q++]; l = (l<<7)|(b&0x7f); if (!(b&0x80)) break; }
                    q += l;
                } else {
                    if (st & 0x80) { run = st; q++; } else st = run;   // ランニングステータス
                    const int nb = ((st & 0xf0) == 0xc0 || (st & 0xf0) == 0xd0) ? 1 : 2;
                    if (q + nb > end) break;
                    const uint8_t a = d[q], b = nb > 1 ? d[q+1] : 0;
                    q += nb;
                    raw.push_back({tick, 1, st, a, b, 0});
                }
            }
            p = q > p + 8 + len ? q : p + 8 + len;
        }
        std::stable_sort(raw.begin(), raw.end(),
                         [](const Raw& a, const Raw& b){ return a.tick != b.tick ? a.tick < b.tick : a.ord < b.ord; });

        const double tpq = div > 0 ? div : 480;      // SMPTE 分解能は稀なので既定にフォールバック
        double sec = 0, us = 500000; uint64_t last = 0; bool firstTempo = true;
        for (const Raw& r : raw) {
            sec += (double)(r.tick - last) / tpq * us / 1e6; last = r.tick;
            if (r.ord < 0) {
                us = r.tempo ? r.tempo : us;
                if (firstTempo) { firstTempo = false; bpm = 6e7 / us; }
                continue;
            }
            ev.push_back({sec, r.s, r.d1, r.d2});
        }
        duration = sec;
        if (ev.empty()) { err = "no MIDI events in file"; return false; }
        return true;
    }
};
