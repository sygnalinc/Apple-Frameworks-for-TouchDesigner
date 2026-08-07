// プラグインが宣言している TouchDesigner Custom OP API バージョンを読み出す。
//
// PluginInfo 構造体の先頭 int32 が apiVersion。setAPIVersion() は
//   apiVersion = version;  → isAPIVersionSupported() で false なら早期return
// という順なので、Min/Max = 0 のゼロ初期化バッファを渡すと opType 等の
// ポインタに触れる前に戻る = 安全に宣言バージョンだけ取り出せる。
//
// 用途: TouchDesigner をダウングレードした状態で新しい SDK 由来のバンドルを
// 配布してしまう事故の検出(common バージョン不一致だと TD は
// "provides an invalid opType name" という紛らわしいエラーで拒否する)。
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: apiscan <mach-o>\n"); return 2; }
    void* h = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (!h) { printf("DLOPEN_FAIL\n"); return 1; }
    const char* syms[] = {"FillTOPPluginInfo","FillCHOPPluginInfo","FillDATPluginInfo","FillSOPPluginInfo"};
    for (int i = 0; i < 4; i++) {
        void (*fn)(void*) = (void(*)(void*))dlsym(h, syms[i]);
        if (!fn) continue;
        static char buf[8192];
        memset(buf, 0, sizeof buf);
        fn(buf);
        int32_t v = *(int32_t*)buf;
        printf("%s api=%d major=%d common=%d\n", syms[i] + 4, v, v & 0xffff, v >> 16);
        return 0;
    }
    printf("NO_FILL_SYMBOL\n");
    return 1;
}
