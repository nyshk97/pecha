#!/usr/bin/env python3
"""Haasのモデル（Core ML）をiCloud Driveに置き、どの版を使うかを pecha-model.json に書く。

使い方:
  python3 -I scripts/place-haas-model.py <版（Hugging Faceのコミット）> [--from <取得済みのフォルダ>]

- Hugging FaceのAPIの値と突き合わせる（LFSのファイルは sha256、小さなファイルは gitのblobのsha1）
- 一時フォルダで揃えて確かめてから、iCloud Driveの Pecha/models/<名前>-<版の先頭7文字>/ へ一度に移す
  （同期の途中で新旧のファイルが混ざらないように、版ごとにフォルダを分ける）
- 最後に Pecha/models/pecha-model.json を書き換える（全ファイルの相対パス・サイズ・sha256）。
  アプリはこのjsonの版が手元のコンパイル済みと違えば、sha256を確かめてからコンパイルし直す
- 古い版のフォルダは消さない（ほかのMacがまだ古い版を読んでいることがある。要らなくなったら手で消す）
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request

REPO = "okayuji/Haas-ja-v1.0-CoreML-INT8"
NAME = "haas-ja-v1.0-int8"
ROOT = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/Pecha/models")
SKIP = {".gitattributes", "README.md"}


def fetch_json(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def digest(path):
    sha256, sha1 = hashlib.sha256(), None
    size = os.path.getsize(path)
    sha1 = hashlib.sha1(b"blob %d\0" % size)
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            sha256.update(block)
            sha1.update(block)
    return size, sha256.hexdigest(), sha1.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("revision")
    ap.add_argument("--from", dest="source", help="取得済みのフォルダ（あれば落とし直さない。中身は確かめる）")
    args = ap.parse_args()

    tree = fetch_json(f"https://huggingface.co/api/models/{REPO}/tree/{args.revision}?recursive=true")
    files = {e["path"]: e for e in tree if e["type"] == "file" and e["path"] not in SKIP}
    if not files:
        sys.exit(f"NG: {args.revision} にファイルが無い")
    revision = fetch_json(f"https://huggingface.co/api/models/{REPO}/revision/{args.revision}")["sha"]
    folder = f"{NAME}-{revision[:7]}"
    dest = os.path.join(ROOT, folder)
    if os.path.exists(dest):
        print(f"既にある: {dest}（中身を確かめ直す）")

    os.makedirs(ROOT, exist_ok=True)
    # 揃えるまではiCloud Driveの外（同じボリューム）に置き、最後に rename で一度に入れる
    staging = os.path.expanduser("~/Library/Caches")
    work = tempfile.mkdtemp(prefix="pecha-placing-", dir=staging) if not os.path.exists(dest) else None
    base = dest if work is None else work
    entries = []
    for rel, e in sorted(files.items()):
        path = os.path.join(base, rel)
        if work is not None:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if args.source and os.path.exists(os.path.join(args.source, rel)):
                shutil.copyfile(os.path.join(args.source, rel), path)
            else:
                url = f"https://huggingface.co/{REPO}/resolve/{revision}/{rel}"
                with urllib.request.urlopen(url, timeout=900) as r, open(path, "wb") as f:
                    shutil.copyfileobj(r, f, 1 << 20)
        if not os.path.exists(path):
            sys.exit(f"NG: {path} が無い（{dest} が揃っていない。消してからやり直す）")
        size, sha256, sha1 = digest(path)
        want = e["lfs"]["oid"] if e.get("lfs") else e["oid"]
        got = sha256 if e.get("lfs") else sha1
        if size != e["size"] or got != want:
            if work is not None:
                shutil.rmtree(work)
            sys.exit(f"NG: {rel} がHugging Faceの値と合わない（size {size}/{e['size']}）")
        entries.append({"path": rel, "size": size, "sha256": sha256})
    if work is not None:
        os.rename(work, dest)

    manifest = {
        "version": revision,
        "folder": folder,
        "source": f"https://huggingface.co/{REPO}/tree/{revision}",
        "files": entries,
    }
    out = os.path.join(ROOT, "pecha-model.json")
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, out)
    total = sum(e["size"] for e in entries)
    print(f"OK: {len(entries)} ファイル（{total:,} B）を {dest} に置き、{out} を {revision[:7]} にした")


if __name__ == "__main__":
    main()
