#!/bin/bash
# dev ビルド（Pecha Dev）に音声ファイルを文字起こしさせて、結果（RAW / TEXT / MS の行）を表示する。
# 使い方: scripts/transcribe-file.sh <audio> [dictionary]
#
# マイク・ホットキーを使わないので TCC の許可が要らない（ad-hoc ビルドでも毎回通る）。
# open 経由（LaunchServices）で起動する。バイナリを直接叩くと TCC が起動した側（ターミナル・Claude Code）で判断される。
# -n で新しいプロセスとして起動するので、常駐中の Pecha Dev を止めなくてよい（フックはタップ・メニューバーを立てない）。
# 辞書を省くと空の一時ファイルを使う（共有の辞書は読み書きしない）。
set -euo pipefail
cd "$(dirname "$0")/.."

AUDIO="${1:?音声ファイルを指定する}"
DICT="${2:-}"
APP="build/Build/Products/Debug/Pecha Dev.app"
[ -d "$APP" ] || { echo "NG: $APP が無い（先に mise run build）" >&2; exit 1; }
[ -f "$AUDIO" ] || { echo "NG: $AUDIO が無い" >&2; exit 1; }
AUDIO="$(cd "$(dirname "$AUDIO")" && pwd)/$(basename "$AUDIO")"

WORK=$(mktemp -d)
trap '/bin/rm -rf "$WORK"' EXIT
if [ -z "$DICT" ]; then
  DICT="$WORK/dictionary.txt"
  : > "$DICT"
fi
DICT="$(cd "$(dirname "$DICT")" && pwd)/$(basename "$DICT")"
OUT="$WORK/out.txt"
: > "$OUT"

open -n -g -W --stdout "$OUT" --stderr "$OUT" "$APP" --args --transcribe-file "$AUDIO" --dictionary "$DICT"
cat "$OUT"
grep -q '^TEXT' "$OUT"
