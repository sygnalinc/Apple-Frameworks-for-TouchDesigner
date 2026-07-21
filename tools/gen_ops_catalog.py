#!/usr/bin/env python3
# ops_catalog.json を .mm ソースから生成(TD不要・best-effort)。
import os, re, json

import os as _os
REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
FAM = {"FillTOPPluginInfo": "TOP", "FillCHOPPluginInfo": "CHOP",
       "FillDATPluginInfo": "DAT", "FillSOPPluginInfo": "SOP"}
APPEND = {"appendToggle": "toggle", "appendInt": "int", "appendFloat": "float",
          "appendString": "string", "appendMenu": "menu", "appendPulse": "pulse",
          "appendTOP": "TOP", "appendFolder": "folder", "appendFile": "file",
          "appendXY": "xy", "appendUV": "uv", "appendRGBA": "rgba", "appendSOP": "SOP",
          "appendCHOP": "CHOP", "appendDAT": "DAT", "appendPython": "python"}

def find_block(text, start_kw):
    i = text.find(start_kw)
    if i < 0:
        return None
    b = text.find("{", i)
    if b < 0:
        return None
    depth = 0
    for j in range(b, len(text)):
        if text[j] == "{": depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[b+1:j]
    return None

def parse_params(body):
    if not body:
        return []
    params = []
    # 各パラメータ宣言の位置
    decls = list(re.finditer(r'OP_(?:Numeric|String)Parameter\s+(\w+)\s*\(\s*"([^"]+)"', body))
    for k, m in enumerate(decls):
        var, name = m.group(1), m.group(2)
        seg = body[m.end(): decls[k+1].start() if k+1 < len(decls) else len(body)]
        ptype = None
        am = re.search(r'->append(\w+)\s*\(', seg)
        if am:
            ptype = APPEND.get("append" + am.group(1), am.group(1).lower())
        p = {"name": name, "type": ptype or "string"}
        # page
        pg = re.search(r'\.page\s*=\s*"([^"]*)"', seg)
        if pg: p["page"] = pg.group(1)
        # default (string or numeric)
        ds = re.search(r'\.defaultValue\s*=\s*"([^"]*)"', seg)
        dn = re.search(r'\.defaultValues\[0\]\s*=\s*([-\d.]+)', seg)
        if ds: p["default"] = ds.group(1)
        elif dn: p["default"] = dn.group(1)
        # menu options (first {"..","..."} string array in seg)
        if p["type"] == "menu":
            arr = re.search(r'\{\s*("(?:[^"]*"\s*,\s*")*[^"]*")\s*\}', seg)
            if arr:
                opts = re.findall(r'"([^"]*)"', arr.group(1))
                if opts: p["menu"] = opts
        params.append(p)
    # ヘルパ関数方式のフォールバック(add*/stringPar/numPar/toggle/pulse 等・第2引数が名前)
    def verb_type(v):
        v = v.lower()
        if "toggle" in v: return "toggle"
        if "pulse" in v: return "pulse"
        if "menu" in v: return "menu"
        if "float" in v: return "float"
        if "int" in v: return "int"
        if "num" in v: return "number"
        if "str" in v or "string" in v: return "string"
        if "folder" in v: return "folder"
        if "file" in v: return "file"
        if "top" in v: return "TOP"
        return "string"
    for m in re.finditer(r'\b(add\w+|stringPar|numPar|intPar|floatPar|toggle|pulse|menuPar|folderPar|topPar|filePar)\s*\(\s*\w+\s*,\s*"([A-Z]\w*)"', body):
        nm = m.group(2)
        if not any(pp["name"] == nm for pp in params):
            params.append({"name": nm, "type": verb_type(m.group(1))})
    return params

def parse_info_chop(text):
    body = find_block(text, "getInfoCHOPChan")
    if not body:
        return []
    arr = re.search(r'\{\s*("(?:[^"]*"\s*,\s*")*[^"]*")\s*\}', body)
    if arr:
        return re.findall(r'"([^"]*)"', arr.group(1))
    return []

catalog = {}
for root, dirs, files in os.walk(REPO):
    dirs[:] = [d for d in dirs if d not in ("build", ".build", ".xcbuild", ".git", "helper", "ios", "node_modules")]
    for fn in files:
        if not fn.endswith(".mm"):
            continue
        path = os.path.join(root, fn)
        text = open(path).read()
        fam = None
        for k, v in FAM.items():
            if k in text:
                fam = v; break
        if not fam:
            continue
        def g(field):
            m = re.search(r'customOPInfo\.%s->setString\("([^"]*)"\)' % field, text)
            return m.group(1) if m else None
        optype = g("opType")
        if not optype:
            continue
        label = g("opLabel"); icon = g("opIcon"); author = g("authorName")
        help_m = re.search(r'opHelpURL->setString\("([^"]*)"\)', text)
        mn = re.search(r'customOPInfo\.minInputs\s*=\s*(\d+)', text)
        mx = re.search(r'customOPInfo\.maxInputs\s*=\s*(\d+)', text)
        folder = os.path.basename(root)
        create = optype + fam                       # create('MlxllmDAT') 用
        params = parse_params(find_block(text, "setupParameters"))
        top_params = [p["name"] for p in params if p["type"] == "TOP"]
        entry = {
            "create": create,
            "opType": optype,
            "label": label,
            "family": fam,
            "icon": icon,
            "minInputs": int(mn.group(1)) if mn else 0,
            "maxInputs": int(mx.group(1)) if mx else 0,
            "author": author,
            "folder": folder,
            "readme": f"{folder}/README.md",
            "helpURL": help_m.group(1) if help_m else None,
            "params": params,
            "topParams": top_params,
            "infoChop": parse_info_chop(text),
            "statusDat": "status" in (find_block(text, "getInfoDATEntries") or ""),
            "example": f"/project1/examples/{folder}",
            "source": os.path.relpath(path, REPO),
        }
        catalog[create] = entry

out = {
    "_note": "TDAppleOps custom op catalog. Generated from .mm sources (best-effort). "
             "Use 'create' with parent().create('<create>', name) or MCP create. "
             "Param defaults/menus are source-derived; for exact live schema, introspect op.pars() in TD.",
    "_count": len(catalog),
    "ops": dict(sorted(catalog.items())),
}
with open(os.path.join(REPO, "ops_catalog.json"), "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("wrote ops_catalog.json:", len(catalog), "ops")
# quick sanity
fams = {}
for e in catalog.values():
    fams[e["family"]] = fams.get(e["family"], 0) + 1
print("by family:", fams)
