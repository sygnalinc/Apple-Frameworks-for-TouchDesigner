// Non-Commercial ライセンスの解像度上限(1280x1280)に出力を収めるための共通ヘルパ。
//
// なぜ要るか:
//   無償の Non-Commercial 版は解像度が 1280x1280 に制限される。上限を超える
//   textureDesc を宣言すると、**TD はクランプ後のサイズでテクスチャを確保したうえで、
//   こちらのバッファをその幅で読む**(リサンプルはしてくれない)。例えば 2560 幅で
//   バイトを並べたものを 1280 幅として読まれるので、行が1行ごとにずれて絵が斜めに崩れる。
//   しかも**エラーは出ない**ので静かに壊れる。実測で Metal Upscale / Screen Capture /
//   ImageIO File In / CoreText / PDFKit が該当した。
//
//   そこでアップロードの直前にこのヘッダで縮小し、textureDesc も縮小後の値にする。
//
// 上限の判定について:
//   C++ SDK に上限を問い合わせる API は無い。`getSuggestedOutputDesc` は Common ページの
//   値を返すだけで、NC でも変わらない(実測)。唯一の手がかりが TD の Python の
//   `licenses.isNonCommercial` なので、それを埋め込み Python で引いている。
//   ビルドには Python.h と -undefined dynamic_lookup が要る:
//     PYINC="/Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11"
//     export TD_EXTRA_CFLAGS="-I $PYINC -undefined dynamic_lookup"
//
// 使い方(アップロード直前・execute 内):
//     if (tdnc::fit(frame.data, frame.width, frame.height, frame.format))
//         myWarning = tdnc::kWarning;      // 縮小したことを利用者に知らせる
//     info.textureDesc.width  = frame.width;   // ← 縮小後の値を宣言する
//     info.textureDesc.height = frame.height;
//
// 注意: data は**行パディング無しの密なバッファ**であること(row bytes == width*bpp)。

#pragma once

#include <Python.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

namespace tdnc {

constexpr uint32_t kMaxDim = 1280;

inline constexpr const char* kWarning =
    "Output was scaled down to fit the 1280x1280 Non-Commercial resolution limit.";

// 1画素あたりのバイト数。0 を返したら未知の形式なので縮小しない(壊すより据え置く)。
inline uint32_t bytesPerPixel(TD::OP_PixelFormat f)
{
    switch (f) {
        case TD::OP_PixelFormat::Mono8Fixed:    return 1;
        case TD::OP_PixelFormat::RG8Fixed:      return 2;
        case TD::OP_PixelFormat::BGRA8Fixed:
        case TD::OP_PixelFormat::RGBA8Fixed:
        case TD::OP_PixelFormat::Mono32Float:   return 4;
        case TD::OP_PixelFormat::RGBA16Float:
        case TD::OP_PixelFormat::RG32Float:     return 8;
        case TD::OP_PixelFormat::RGBA32Float:   return 16;
        default:                                return 0;
    }
}

// 32bit float 系か(平均する際に float として扱う必要がある)。
inline bool isFloat32(TD::OP_PixelFormat f)
{
    return f == TD::OP_PixelFormat::Mono32Float ||
           f == TD::OP_PixelFormat::RG32Float   ||
           f == TD::OP_PixelFormat::RGBA32Float;
}

// TD が Non-Commercial 相当で動いているか。`licenses.isNonCommercial` を引く。
// 毎回 Python を触ると重いので結果をキャッシュし、一定回数ごとに引き直す
// (セッションの途中で app.addNonCommercialLimit() されることがあるため)。
inline bool active()
{
    static std::atomic<int> cached{-1};   // -1=未取得 / 0=通常 / 1=NC
    static std::atomic<int> ttl{0};

    const int prev = cached.load(std::memory_order_relaxed);
    if (prev >= 0 && ttl.fetch_sub(1, std::memory_order_relaxed) > 0)
        return prev == 1;

    int result = (prev >= 0) ? prev : 0;
    if (Py_IsInitialized()) {
        PyGILState_STATE gil = PyGILState_Ensure();
        if (PyObject* td = PyImport_ImportModule("td")) {
            if (PyObject* lic = PyObject_GetAttrString(td, "licenses")) {
                if (PyObject* nc = PyObject_GetAttrString(lic, "isNonCommercial")) {
                    result = (PyObject_IsTrue(nc) == 1) ? 1 : 0;
                    Py_DECREF(nc);
                }
                Py_DECREF(lic);
            }
            Py_DECREF(td);
        }
        PyErr_Clear();          // 取れなくても落とさない。通常ライセンス扱いで続行する
        PyGILState_Release(gil);
    }
    cached.store(result, std::memory_order_relaxed);
    ttl.store(120, std::memory_order_relaxed);   // 60fps で約2秒ごとに引き直す
    return result == 1;
}

// 縮小の実体。data はバイト列(行パディング無し)。呼び出しは下の fit() を使う。
// 8bit / 32bit float はボックス平均、それ以外(16F 等)は最近傍で間引く。
inline bool fitRaw(std::vector<uint8_t>& data, uint32_t& w, uint32_t& h, TD::OP_PixelFormat fmt)
{
    if (w <= kMaxDim && h <= kMaxDim)
        return false;                       // 上限内。Python にも触らない安いパス
    const uint32_t bpp = bytesPerPixel(fmt);
    if (bpp == 0 || w == 0 || h == 0)
        return false;
    if (data.size() < (size_t)w * h * bpp)
        return false;                       // 想定と違うバッファには触らない
    if (!active())
        return false;                       // 通常ライセンスなら何もしない

    const double s = (double)kMaxDim / (double)(w > h ? w : h);
    const uint32_t nw = (uint32_t)(w * s) > 0 ? (uint32_t)(w * s) : 1;
    const uint32_t nh = (uint32_t)(h * s) > 0 ? (uint32_t)(h * s) : 1;

    std::vector<uint8_t> out((size_t)nw * nh * bpp);

    if (isFloat32(fmt)) {
        const uint32_t comps = bpp / 4;
        const float* src = reinterpret_cast<const float*>(data.data());
        float* dst = reinterpret_cast<float*>(out.data());
        for (uint32_t y = 0; y < nh; ++y) {
            const uint32_t y0 = (uint32_t)((uint64_t)y * h / nh);
            uint32_t y1 = (uint32_t)((uint64_t)(y + 1) * h / nh);
            if (y1 <= y0) y1 = y0 + 1;
            for (uint32_t x = 0; x < nw; ++x) {
                const uint32_t x0 = (uint32_t)((uint64_t)x * w / nw);
                uint32_t x1 = (uint32_t)((uint64_t)(x + 1) * w / nw);
                if (x1 <= x0) x1 = x0 + 1;
                for (uint32_t c = 0; c < comps; ++c) {
                    double acc = 0.0;
                    for (uint32_t sy = y0; sy < y1; ++sy)
                        for (uint32_t sx = x0; sx < x1; ++sx)
                            acc += src[((size_t)sy * w + sx) * comps + c];
                    dst[((size_t)y * nw + x) * comps + c] =
                        (float)(acc / ((y1 - y0) * (x1 - x0)));
                }
            }
        }
    } else if (bpp <= 4 && fmt != TD::OP_PixelFormat::Mono32Float) {
        // 8bit 系(1/2/4 バイト = 1画素あたり bpp 個の uint8 成分)
        for (uint32_t y = 0; y < nh; ++y) {
            const uint32_t y0 = (uint32_t)((uint64_t)y * h / nh);
            uint32_t y1 = (uint32_t)((uint64_t)(y + 1) * h / nh);
            if (y1 <= y0) y1 = y0 + 1;
            for (uint32_t x = 0; x < nw; ++x) {
                const uint32_t x0 = (uint32_t)((uint64_t)x * w / nw);
                uint32_t x1 = (uint32_t)((uint64_t)(x + 1) * w / nw);
                if (x1 <= x0) x1 = x0 + 1;
                const uint32_t n = (y1 - y0) * (x1 - x0);
                for (uint32_t c = 0; c < bpp; ++c) {
                    uint32_t acc = 0;
                    for (uint32_t sy = y0; sy < y1; ++sy)
                        for (uint32_t sx = x0; sx < x1; ++sx)
                            acc += data[((size_t)sy * w + sx) * bpp + c];
                    out[((size_t)y * nw + x) * bpp + c] = (uint8_t)(acc / n);
                }
            }
        }
    } else {
        // 16F など。成分を解釈せずに最近傍で間引く(平均すると壊れるため)
        for (uint32_t y = 0; y < nh; ++y) {
            const uint32_t sy = (uint32_t)((uint64_t)y * h / nh);
            for (uint32_t x = 0; x < nw; ++x) {
                const uint32_t sx = (uint32_t)((uint64_t)x * w / nw);
                memcpy(&out[((size_t)y * nw + x) * bpp],
                       &data[((size_t)sy * w + sx) * bpp], bpp);
            }
        }
    }

    data.swap(out);
    w = nw;
    h = nh;
    return true;
}

// 要素型に依存しない入口。std::vector<uint8_t> でも std::vector<uint16_t>(RGBA16Float 等)
// でも渡せる。中ではバイト列として扱う。
template <class T>
inline bool fit(std::vector<T>& data, uint32_t& w, uint32_t& h, TD::OP_PixelFormat fmt)
{
    if (w <= kMaxDim && h <= kMaxDim)
        return false;                       // 早期リターン(コピーもPythonも発生しない)

    std::vector<uint8_t> bytes(data.size() * sizeof(T));
    memcpy(bytes.data(), data.data(), bytes.size());
    if (!fitRaw(bytes, w, h, fmt))
        return false;
    data.assign(reinterpret_cast<const T*>(bytes.data()),
                reinterpret_cast<const T*>(bytes.data() + bytes.size()));
    return true;
}

// uint8_t のときは詰め替え不要なので直接渡す
template <>
inline bool fit<uint8_t>(std::vector<uint8_t>& data, uint32_t& w, uint32_t& h, TD::OP_PixelFormat fmt)
{
    return fitRaw(data, w, h, fmt);
}

}   // namespace tdnc
