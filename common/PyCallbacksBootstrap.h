// TD Custom OP 用: Callbacks DAT の自動生成(GLSL風ドックチップ)+ Pythonコールバック発火ヘルパ。
// 元実装・検証は CoreWLANScan/CoreWLANScanCHOP.mm(2026-07-22)。同じ仕組みを他OPへ横展開する時はこれを使う。
//
// 使い方:
//   1. Fill*PluginInfo で i->customOPInfo.pythonCallbacksDAT = <stub文字列>;
//   2. execute で成功するまで毎cook: if (!myBootstrapped) myBootstrapped = tdpycb::bootstrapCallbacksDAT(myNode, <stub>);
//      (生成直後の cook はカスタムパラメータ未生成で必ず失敗するため、リトライが必須)
//   3. トグルの off→on 遷移などで tdpycb::firePythonCallback(myNode, "onXxx", true);
//
// 必要ビルドフラグ(build.sh):
//   -I /Applications/TouchDesigner.app/Contents/Frameworks/Python.framework/Versions/3.11/include/python3.11
//   -undefined dynamic_lookup   (Py_* シンボルは実行時に TD 本体から解決)
//
// 実機で踏んだ罠(詳細は skill pitfalls.md「Python コールバック」節):
//   - OP_NodeInfo::opPath は空のことがある → createArgumentsTuple の args[0](自ノードPyObject)で参照
//   - PyRun の __main__ に op/textDAT は無い → import td で明示
//   - チップの↑開/↓閉の実体は showDocked(expose=False は「×」チップになるので使わない)
#pragma once
#include <Python.h>
#include <string>
#include <vector>
#include <utility>
#include "CPlusPlus_Common.h"

namespace tdpycb {

// 自ノードの数値パラメータへ書き戻す。
//
// C++ SDK には「自分のパラメータを設定する」APIが無い(読むのは OP_Inputs、書く口は無い)。
// 埋め込み Python 経由で書くのが唯一の手。cook スレッドから呼ぶこと
// (AppKit のコールバック等、別スレッドから触ると THREAD CONFLICT になる。CoreText で踏んだ)。
//
// 用途例: ファイルを開いたとき、そのファイルが持っている設定(RAWの as-shot ホワイトバランス等)を
// パラメータに流し込んで、ユーザーがそこから編集できるようにする。
inline bool setFloatPars(const TD::OP_NodeInfo* node,
                         const std::vector<std::pair<std::string, double>>& vals)
{
    if (!node || !node->context || vals.empty()) return false;
    PyGILState_STATE g = PyGILState_Ensure();
    std::string py = "__tdsp_ok = False\ntry:\n\tn = __tdsp_node\n";
    for (const auto& kv : vals) {
        char line[128];
        snprintf(line, sizeof line, "\tn.par.%s = %.6f\n", kv.first.c_str(), kv.second);
        py += line;
    }
    py += "\t__tdsp_ok = True\nexcept Exception:\n";
    py += "\timport traceback as __tdsp_tb\n\t__tdsp_err = __tdsp_tb.format_exc()\n";
    bool ok = false;
    PyObject* main = PyImport_AddModule("__main__");
    PyObject* dict = main ? PyModule_GetDict(main) : nullptr;
    PyObject* args = node->context->createArgumentsTuple(0, nullptr);
    if (dict && args) {
        PyDict_SetItemString(dict, "__tdsp_node", PyTuple_GET_ITEM(args, 0));
        PyObject* r = PyRun_String(py.c_str(), Py_file_input, dict, dict);
        if (r) Py_DECREF(r); else PyErr_Clear();
        PyObject* v = PyDict_GetItemString(dict, "__tdsp_ok");
        ok = v && PyObject_IsTrue(v) == 1;
        PyDict_DelItemString(dict, "__tdsp_node");
    }
    if (args) Py_DECREF(args);
    PyGILState_Release(g);
    return ok;
}

// Callbacks DAT が未接続なら、雛形入り Text DAT を生成してホストへドック接続(閉じた↓チップ)。
// 戻り値: callbacks が接続済みなら true(以後呼ばなくてよい)
inline bool bootstrapCallbacksDAT(const TD::OP_NodeInfo* node, const char* stubs)
{
    if (!node || !node->context) return false;
    PyGILState_STATE g = PyGILState_Ensure();
    std::string py;
    py += "__tdcb_ok = False\n";
    py += "try:\n";
    py += "\timport td\n";
    py += "\tn = __tdcb_node\n";
    py += "\tif n and hasattr(n.par, 'callbacks'):\n";
    py += "\t\tif not n.par.callbacks.eval():\n";
    py += "\t\t\tp = n.parent()\n";
    py += "\t\t\tnm = n.name + '_callbacks'\n";
    py += "\t\t\td = p.op(nm)\n";
    py += "\t\t\tif not d:\n";
    py += "\t\t\t\td = p.create(td.textDAT, nm)\n";
    py += "\t\t\t\td.text = '''";
    py += stubs;
    py += "'''\n";
    py += "\t\t\t\td.dock = n\n";           // ホストへドック(GLSLのシェーダDATと同型)
    py += "\t\t\t\td.expose = True\n";      // チップ表示(Falseだと×チップ)
    py += "\t\t\t\td.viewer = True\n";      // 開いた時にテキストが見える
    py += "\t\t\t\td.showDocked = False\n"; // 既定は閉じた↓チップ(開閉の実体はこのフラグ)
    py += "\t\t\tn.par.callbacks = nm\n";
    // 既に自動生成済みの DAT には、後から増えたコールバックが入っていない。
    // (stub は生成時にしか書かれないため、プラグインを更新しても古い DAT のままになる)
    // 自動生成した名前のものに限り、不足している def だけを追記する。
    // 注意: par.callbacks.eval() は **文字列ではなく DAT オブジェクト**を返す(実測)
    py += "\t\t__tdcb_d = n.par.callbacks.eval()\n";
    py += "\t\tif __tdcb_d is not None and __tdcb_d.name == n.name + '_callbacks':\n";
    py += "\t\t\tfor __blk in ('\\n' + __tdcb_stub).split('\\ndef ')[1:]:\n";
    py += "\t\t\t\t__nm = __blk.split('(')[0].strip()\n";
    py += "\t\t\t\tif ('def ' + __nm) not in __tdcb_d.text:\n";
    py += "\t\t\t\t\t__tdcb_d.text = __tdcb_d.text.rstrip() + '\\n\\ndef ' + __blk.rstrip() + '\\n'\n";
    py += "\t\t__tdcb_ok = bool(n.par.callbacks.eval())\n";
    py += "except Exception:\n";
    py += "\timport traceback as __tdcb_tb\n";
    py += "\t__tdcb_err = __tdcb_tb.format_exc()\n";   // textport から調査できるよう残す
    bool ok = false;
    PyObject* main = PyImport_AddModule("__main__");                // borrowed
    PyObject* dict = main ? PyModule_GetDict(main) : nullptr;      // borrowed
    PyObject* args = node->context->createArgumentsTuple(0, nullptr); // [0]=op
    if (dict && args) {
        PyDict_SetItemString(dict, "__tdcb_node", PyTuple_GET_ITEM(args, 0));
        PyObject* stubStr = PyUnicode_FromString(stubs);
        if (stubStr) { PyDict_SetItemString(dict, "__tdcb_stub", stubStr); Py_DECREF(stubStr); }
        PyObject* r = PyRun_String(py.c_str(), Py_file_input, dict, dict);
        if (r) Py_DECREF(r); else PyErr_Clear();
        PyObject* v = PyDict_GetItemString(dict, "__tdcb_ok");     // borrowed
        ok = v && PyObject_IsTrue(v) == 1;
        PyDict_DelItemString(dict, "__tdcb_node");
        if (PyDict_GetItemString(dict, "__tdcb_stub")) PyDict_DelItemString(dict, "__tdcb_stub");
    }
    if (args) Py_DECREF(args);
    PyGILState_Release(g);
    return ok;
}

// bool 1引数のコールバックを発火する(例: onInfoDAT(op, enabled))。
// Callbacks DAT 未接続・関数未定義なら何も起きない(安全)。cook(メインスレッド)から呼ぶこと。
inline void firePythonCallback(const TD::OP_NodeInfo* node, const char* fn, bool enabled)
{
    if (!node || !node->context) return;
    PyObject* args = node->context->createArgumentsTuple(1, nullptr); // [0]=op
    if (!args) return;
    PyTuple_SET_ITEM(args, 1, PyBool_FromLong(enabled ? 1 : 0));
    PyObject* r = node->context->callPythonCallback(fn, args, nullptr, nullptr);
    Py_DECREF(args);
    if (r) Py_DECREF(r);
}

} // namespace tdpycb
