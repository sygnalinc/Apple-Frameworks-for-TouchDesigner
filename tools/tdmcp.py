#!/usr/bin/env python3
"""TouchDesigner の td_mcp_server へ JSON-RPC を直接投げる最小クライアント。

`mcp__touchdesigner__*` ツールがセッションに未登録/切断中でも、TD 内の
td_mcp_server コンポーネント(demo.toe の /project1/td_mcp_server)が待ち受けている
HTTP エンドポイントを直接叩けば TD を駆動できる。

使い方:
    python3 tools/tdmcp.py < script.py        # stdin から Python を渡す
    echo "print(op('/project1').name)" | python3 tools/tdmcp.py
    python3 tools/tdmcp.py --port 9988 < script.py

ハマりどころ(実測):
  - **複数行のコードは print も最終式も返らないことがある。**
    処理全体を1つの関数に入れて `print(go())` で呼ぶのが確実。
  - **exec のスコープ分離**でモジュール変数が関数から見えない。
    定数はデフォルト引数で渡す: `def go(NOTE=...):`
  - **TD のメインスレッドで time.sleep すると cook が完全に止まる。**
    経過を測るときは TD 側で値を読む → シェルで待つ → もう一度読む。
  - TOP の出力確認は `op(...).save('/tmp/x.png')` → Read で視認。
"""
import json
import subprocess
import sys
import urllib.request

DEFAULT_PORT = 9988


def find_port():
    """起動中の TouchDesigner が LISTEN しているポートを拾う(見つからなければ既定)。"""
    try:
        pid = subprocess.run(["pgrep", "-x", "TouchDesigner"],
                             capture_output=True, text=True).stdout.split()
        if not pid:
            return DEFAULT_PORT
        out = subprocess.run(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid[0]],
            capture_output=True, text=True).stdout
        for line in out.splitlines()[1:]:
            if ":" in line:
                return int(line.rsplit(":", 1)[1].split()[0])
    except Exception:
        pass
    return DEFAULT_PORT


def post(base, payload, sid=None):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream"}
    if sid:
        h["Mcp-Session-Id"] = sid
    req = urllib.request.Request(base, json.dumps(payload).encode(), h)
    r = urllib.request.urlopen(req, timeout=120)
    body = r.read().decode()
    # Streamable HTTP は SSE で返ることがある
    if body.startswith("event:") or body.startswith("data:") or "\ndata:" in body:
        for line in body.splitlines():
            if line.startswith("data:"):
                body = line[5:].strip()
                break
    return (json.loads(body) if body.strip() else None), r.headers.get("Mcp-Session-Id")


def run(code, port):
    base = f"http://127.0.0.1:{port}/mcp"
    _, sid = post(base, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                    "clientInfo": {"name": "tdmcp.py", "version": "1.0"}}})
    post(base, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    res, _ = post(base, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                         "params": {"name": "run", "arguments": {"code": code}}}, sid)
    try:
        out = res["result"]["content"][0]["text"]
        try:
            j = json.loads(out)
            print(j.get("result", {}).get("output", out) if isinstance(j, dict) else out)
        except Exception:
            print(out)
    except Exception:
        print(json.dumps(res, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    port = DEFAULT_PORT
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    else:
        port = find_port()
    run(sys.stdin.read(), port)
