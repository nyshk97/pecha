#!/bin/bash
# dev ビルド（Pecha Dev）に音声ファイルを文字起こしさせて、結果（RAW / TEXT / MS の行）を表示する。
# 使い方: scripts/transcribe-file.sh [--engine haas|os] [--model-dir <dir>] [--haas-fail error|timeout] <audio> [dictionary]
#
# 出力は ENGINE（haas / os と、OS になった理由）・RAW（認識そのまま）・TEXT（辞書の置き換え後）・MS（時間）の行。
# --engine を省くとアプリと同じ選び方（Haas の準備が終わってから、使えれば Haas）。--model-dir は iCloud Drive の
# Pecha/models/ と同じ形のフォルダ（そのときはコンパイル先も一時フォルダになる）。--haas-fail は Haas をわざと失敗させる。
#
# マイク・ホットキーを使わないので TCC の許可が要らない（ad-hoc ビルドでも毎回通る）。
# open 経由（LaunchServices）で起動する。バイナリを直接叩くと TCC が起動した側（ターミナル・Claude Code）で判断される。
# -n で新しいプロセスとして起動するので、常駐中の Pecha Dev を止めなくてよい（フックはタップ・メニューバーを立てない）。
# 辞書を省くと空の一時ファイルを使う（共有の辞書は読み書きしない）。
set -euo pipefail
cd "$(dirname "$0")/.."

HOOK_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --engine|--model-dir|--cache-dir|--haas-fail)
      [ -n "${2:-}" ] || { echo "NG: $1 に値が要る" >&2; exit 1; }
      if [ "$1" = --model-dir ] || [ "$1" = --cache-dir ]; then
        mkdir -p "$2"
        [ -d "$2" ] || { echo "NG: $2 が無い" >&2; exit 1; }
        HOOK_ARGS+=("$1" "$(cd "$2" && pwd)")
      else
        HOOK_ARGS+=("$1" "$2")
      fi
      shift 2 ;;
    *) break ;;
  esac
done
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

open -n -g -W --stdout "$OUT" --stderr "$OUT" "$APP" --args --transcribe-file "$AUDIO" --dictionary "$DICT" ${HOOK_ARGS[@]+"${HOOK_ARGS[@]}"}
cat "$OUT"
grep -q '^TEXT' "$OUT"
