#!/usr/bin/env python3
"""自分の声のサンプルを、OS の認識と Haas の両方で文字起こしして並べる（dev 版の --transcribe-file のフックを使う）。

使い方:
  python3 -I scripts/compare-engines.py [サンプルのフォルダ] [--dictionary <辞書>] [--model-dir <dir>]

- サンプルは既定で iCloud Drive の Pecha/samples/。音声（m4a・wav・aiff・caf・mp3）と、同じ名前の .txt（何と言ったかの正しい文。1 行）
- 辞書は既定で Dropbox の共有の辞書。サンプル・辞書・Haas のモデルは写してから渡す（dev 版に iCloud Drive・Dropbox を触らせない。
  ad-hoc のビルドが触ると許可の確認が出て、答えるまで止まる）。モデルは ~/Library/Caches/pecha-compare/models に写し、
  コンパイル先も ~/Library/Caches/pecha-compare/compiled に固定する（初回だけ Neural Engine の準備で約 80 秒、2 回目からは速い）
- .txt があれば、正しい文との違い（空白と句読点を除いた文字の編集距離）を、辞書なし（RAW）・辞書あり（TEXT）で数える。
  違う箇所は［認識→正しい］の形で印をつける
- 結果の本文は stdout にだけ出す（声の中身なので、ファイルやリポジトリに残さない）
- 認識時間は 1 本ごとにアプリを起動し直すので初回の数字になる。参考にとどめる
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLES = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/Pecha/samples")
MODELS = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/Pecha/models")
CACHE = os.path.expanduser("~/Library/Caches/pecha-compare")
PUNCT = set("、。，．,.!?！？・「」『』（）()")
DICTIONARY = os.path.expanduser("~/Library/CloudStorage/Dropbox/settings/pecha/dictionary.txt")
AUDIO = (".m4a", ".wav", ".aiff", ".aif", ".caf", ".mp3")


def normalize(s):
    return "".join(c for c in s if not c.isspace() and c not in PUNCT)


def distance(a, b):
    a, b = normalize(a), normalize(b)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def marked(got, truth):
    """認識の文のうち、正しい文と違う箇所に［認識→正しい］の印をつける（空白と句読点は比べない）"""
    import difflib
    a, b = normalize(got), normalize(truth)
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op == "equal":
            out.append(a[i1:i2])
        else:
            out.append(f"［{a[i1:i2] or '∅'}→{b[j1:j2] or '∅'}］")
    return "".join(out)


SF_DATALESS = 0x40000000


def dataless_items(path):
    """中身が手元に無いもの（dataless）の一覧。フォルダならその下も見る"""
    found = []
    if os.lstat(path).st_flags & SF_DATALESS:
        found.append(path)
    if os.path.isdir(path):
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                full = os.path.join(root, name)
                if os.lstat(full).st_flags & SF_DATALESS:
                    found.append(full)
    return found


def materialize(path):
    """iCloud が中身を手元から消していれば（dataless）取り込む。Python から直接読むと EDEADLK で断られるので brctl に頼む。
    brctl download はフォルダを渡しても中まで降りないので、1 つずつ頼む"""
    items = dataless_items(path)
    if not items:
        return
    print(f"iCloud から取り込み中: {os.path.basename(path)}（{len(items)} 個）", flush=True)
    for item in items:
        subprocess.run(["brctl", "download", item], capture_output=True)
    deadline = time.time() + 600
    while (left := dataless_items(path)):
        if time.time() > deadline:
            sys.exit(f"NG: {left[0]} ほか {len(left)} 個を iCloud から取り込めない")
        for item in left:
            subprocess.run(["brctl", "download", item], capture_output=True)
        time.sleep(1)


def local_models():
    """iCloud Drive のモデルを手元に写す（版が同じなら写し直さない）"""
    src_manifest = os.path.join(MODELS, "pecha-model.json")
    materialize(src_manifest)
    with open(src_manifest) as f:
        manifest = json.load(f)
    dest = os.path.join(CACHE, "models")
    dest_manifest = os.path.join(dest, "pecha-model.json")
    if os.path.exists(dest_manifest):
        with open(dest_manifest) as f:
            if json.load(f).get("version") == manifest["version"]:
                return dest
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    materialize(os.path.join(MODELS, manifest["folder"]))
    # cp -c は APFS の複製（容量を食わない）。iCloud が中身を手元から消していれば取り込む
    subprocess.run(["cp", "-cR", os.path.join(MODELS, manifest["folder"]), dest + "/"], check=True)
    shutil.copyfile(src_manifest, dest_manifest)
    return dest


def run(engine, audio, dictionary, model_dir):
    cmd = ["bash", os.path.join(ROOT, "scripts/transcribe-file.sh"), "--engine", engine]
    if engine == "haas":
        cmd += ["--model-dir", model_dir, "--cache-dir", os.path.join(CACHE, "compiled")]
    cmd += [audio, dictionary]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    lines = dict(l.split("\t", 1) for l in out.splitlines() if "\t" in l)
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("samples", nargs="?", default="")
    ap.add_argument("--dictionary", default=DICTIONARY)
    ap.add_argument("--model-dir", default=None, help="Pecha/models/ と同じ形のフォルダ（省略時は iCloud Drive のものを手元に写して使う）")
    args = ap.parse_args()
    src = args.samples or SAMPLES
    if not os.path.isdir(src):
        sys.exit(f"NG: {src} が無い（mise run record-samples で録る）")
    materialize(src)

    model_dir = args.model_dir or local_models()
    work = tempfile.mkdtemp(prefix="pecha-compare-")
    try:
        dictionary = os.path.join(work, "dictionary.txt")
        if os.path.exists(args.dictionary):
            shutil.copyfile(args.dictionary, dictionary)
        else:
            open(dictionary, "w").close()
        names = sorted(n for n in os.listdir(src) if n.lower().endswith(AUDIO))
        if not names:
            sys.exit(f"NG: {src} に音声が無い")
        totals = {k: 0 for k in ("os_raw", "os_text", "haas_raw", "haas_text")}
        counted = 0
        for name in names:
            audio = os.path.join(work, name)
            shutil.copyfile(os.path.join(src, name), audio)
            truth_path = os.path.join(src, os.path.splitext(name)[0] + ".txt")
            truth = open(truth_path).read().strip() if os.path.exists(truth_path) else None
            results = {e: run(e, audio, dictionary, model_dir) for e in ("os", "haas")}
            print(f"== {name}")
            if truth is not None:
                print(f"   正しい文  {truth}")
            for engine in ("os", "haas"):
                r = results[engine]
                if "ERROR" in r or "TEXT" not in r:
                    print(f"   {engine:4}  ERROR {r.get('ERROR', '出力が無い')}")
                    continue
                used = r.get("ENGINE", "").split("\t")[0]
                note = "" if used == engine else f"（{r.get('ENGINE')}）"
                print(f"   {engine:4}  {r['TEXT']}{note}")
                if truth is not None:
                    raw, text = distance(r["RAW"], truth), distance(r["TEXT"], truth)
                    totals[f"{engine}_raw"] += raw
                    totals[f"{engine}_text"] += text
                    if text:
                        print(f"         {marked(r['TEXT'], truth)}")
                    print(f"         違い: 辞書なし {raw} / 辞書あり {text}   {r.get('MS', '')}")
            if truth is not None:
                counted += 1
        print()
        if counted:
            print(f"正しい文がある {counted} 本の合計（空白と句読点を除いた文字の編集距離）")
            print(f"  OS    辞書なし {totals['os_raw']} / 辞書あり {totals['os_text']}")
            print(f"  Haas  辞書なし {totals['haas_raw']} / 辞書あり {totals['haas_text']}")
        else:
            print("正しい文（.txt）が無いので、違いは数えていない")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
