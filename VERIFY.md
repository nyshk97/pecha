# 動作確認手順

## ビルドとテスト

```bash
mise run build          # Debug（Pecha Dev）。署名 xcconfig が無ければ ad-hoc で通る
mise run build-release  # Release（Pecha）
mise run test           # Sources/Core の純粋関数（ホットキーの状態遷移・辞書の読み込み・置き換え・追記・音量）。辞書の読みの検査表は dictionary-reading: fixed= kept= known_miss= known_false_positive= を出す
mise run run            # /Applications/Pecha Dev.app に置いて起動し直す（旧プロセスの終了を待つ。許可のダイアログが出る）
```

dev と常用で Info.plist が分かれていることの確認（dev に `SUFeedURL` の値が**無い**こと）:

```bash
for c in Debug Release; do n=$([ $c = Debug ] && echo "Pecha Dev" || echo Pecha)
  p="build/Build/Products/$c/$n.app/Contents/Info.plist"
  for k in CFBundleIdentifier CFBundleDisplayName CFBundleVersion SUFeedURL; do
    printf '%s %s=' $c $k; /usr/libexec/PlistBuddy -c "Print :$k" "$p"; done; done
```

配布用の再署名の順序（Sparkle の内側から署名し直す）が壊れていないこと。Claude Code のセッション（`CLAUDECODE`）から叩くと
keychain に触らず ad-hoc で署名し、`verify --deep --strict`・get-task-allow 無し・`audio-input` の entitlement ありだけを見て zip の手前で止まる:

```bash
bash scripts/make-release-zip.sh   # OK: ad-hoc で再署名し、… を確かめた（zip は作らない）
```

## 文字起こしと辞書（TCC の許可が要らない）

マイク・ホットキーを使わず、音声ファイルを実機能と同じ `Transcriber` と辞書の置き換えに通す（dev 版のフック `--transcribe-file`）。
ad-hoc ビルドでも毎回通る。結果の本文は stdout（`RAW` = 認識そのまま / `TEXT` = 辞書の置き換え後 / `MS` = 時間）に出て、ログには文字数だけ残る:

```bash
say -v Kyoko -o /tmp/names.aiff "クロードにきいてみます。なまためさんにもつたえてください。"   # 読みはかなで渡す
printf '生ため => 生天目\n' > /tmp/dict.txt
mise run transcribe /tmp/names.aiff /tmp/dict.txt
# RAW   クロードに聞いてみます。生ためさんにも伝えてください。
# TEXT  クロードに聞いてみます。生天目さんにも伝えてください。
```

- 辞書を省くと空の一時ファイルになる。**共有の辞書（Dropbox）を `--dictionary` に渡さない**: Dropbox の下のファイルに触ると
  「“Pecha Dev.app” が “Dropbox” で管理されているファイルにアクセスしようとしています」の確認が出て、答えるまで止まる（ad-hoc はビルドのたびに出直す）
- `open -n` で別プロセスとして起動するので、常駐中の Pecha Dev は止めなくてよい（フックはタップ・メニューバーを立てずに終了する）

## 通常の起動（セッションから）

許可のダイアログを出さず、辞書は一時ファイルで起動して、ログで起動の流れを見る（dev 版だけの `--no-prompt` / `--dictionary`）:

```bash
open -g "build/Build/Products/Debug/Pecha Dev.app" --args --no-prompt --dictionary /tmp/dict.txt
tail ~/Library/Logs/pecha/pecha-dev.log   # launch → menu.installed → permission ax=… mic=… → dict.loaded → asr.ready
pkill -x "Pecha Dev"
```

2 つ目を起動すると `launch.already_running` を書いて終了する（シングルインスタンス）。

## 実機の確認（ユーザーが署名済みのビルドで行う）

マイク・アクセシビリティの許可が要るので、セッションの ad-hoc ビルドでは確かめられない。`mise run signing` 済みの自分の Terminal で `mise run run`（dev は右 ⌘ + Space / 右 ⌥ + 3）。

- 押して話して離すと前面のアプリ（エディタ・ブラウザ・Slack・ターミナル）に貼られる。話した本文がクリップボードに残っている（⌘V でもう一度貼れる）
- ⌘ + Space が Spotlight・入力ソースの切り替えに漏れない。keyrc を動かしたまま短く押しても入力ソースが変わらない
- ⌘ を先に離しても Space のリピートが打ち込まれない
- 誤認識を選択して右 ⌥ + 数字 → 正しい語を入れて Enter → その場で置き換わり、次の録音から直って出る
- HUD と辞書パネルが、内蔵画面だけのとき・Studio Display を足した 2 枚のときの両方でマウスのある画面に出る
- 押した瞬間に HUD が出る（点は灰色）→ マイクが動き出すと赤になり、同時に開始音（Funk）が鳴る。Studio Display をつないでいて数秒空けた 1 回目でも、HUD が出るまで待たされない

## ログ

`~/Library/Logs/pecha/pecha-dev.log`（常用版は `pecha.log`）。先頭の語がイベント名。**文字起こしの本文は書かない**（文字数だけ）:

`launch` / `launch.already_running` / `menu.installed` / `permission ax= mic= prompt=` / `ax.trusted value= when=` / `mic.requesting` / `mic.answered` /
`tap.created` / `tap.create_failed` / `tap.reenabled reason=timeout|user_input|watchdog|wake` / `system.woke` / `secure_input.on|off front=` /
`hotkey.down` / `hotkey.up reason=space_up|cmd_up|lost ms=` / `record.start` / `record.stop reason= ms= discard=` / `record.blocked reason=mic|asr_not_ready` / `record.failed error= current=` / `audio.started input=` /
`asr.assets_installing` / `asr.ready ms= format=` / `asr.prepare_failed` / `asr.session_ready ms=` / `asr.done chars= finalize_ms=` / `asr.empty` / `asr.failed` /
`paste.done what=dictation|dict_replace chars=` / `clipboard.restored what= rewrites=` / `clipboard.restore_skipped` /
`hotkey.dictionary` / `dict.selection via=ax|menu|cmd_c|none chars=` / `dict.panel_opened` / `dict.panel_closed reason=submitted|escape|lost_focus|toggle` /
`dict.loaded entries=` / `dict.load_failed` / `dict.created` / `dict.add` / `dict.add_failed` / `dict.applied hits=` / `dict.replaced via=ax` / `dict.replace_ax_failed` /
`update.started` / `update.disabled` / `login_item.registered` / `login_item.requires_approval` / `hook.transcribe`

「押しても反応しない」ときは、灰色の HUD が出たか（出なければキーが届いていない。開始音はマイクが動き出してから鳴る）と、`tap.reenabled`・`secure_input.on`・`ax.trusted value=false` の有無を見る。

「押してから録音が始まるまで遅い」ときは、`hotkey.down` から `audio.started` までの差を押下ごとに見る（マイクの起動時間。内蔵マイクで約 130ms、
USB の Studio Display のマイクで約 550ms）。`hotkey.up ms=` はタップがキーを見た時刻からの長さなので、`hotkey.up` の時刻から引くと
タップが押下を見た時刻が分かり、`hotkey.down` との差がメインスレッドの詰まりになる（効果音・マイクの起動をメインで待っていた頃は、
出力デバイスが休止している 1 回目だけ約 450ms あった）:

```bash
python3 - <<'PY'
import re, datetime
ev = [(datetime.datetime.strptime(m[1], '%Y-%m-%d %H:%M:%S.%f').timestamp(), m[2], m[3])
      for m in (re.match(r'(\S+ \S+) (\S+)(.*)', l) for l in open('/Users/d0ne1s/Library/Logs/pecha/pecha.log')) if m]
for i, (t, n, _) in enumerate(ev):
    if n != 'hotkey.down': continue
    nxt = {n2: (t2, a2) for t2, n2, a2 in reversed(ev[i + 1:i + 12])}
    if 'audio.started' not in nxt or 'hotkey.up' not in nxt: continue
    tap = nxt['hotkey.up'][0] - int(re.search(r'ms=(\d+)', nxt['hotkey.up'][1])[1]) / 1000
    print(datetime.datetime.fromtimestamp(t).strftime('%m-%d %H:%M:%S'),
          f"tap→down={int((t - tap) * 1000)}ms down→audio={int((nxt['audio.started'][0] - t) * 1000)}ms")
PY
```

