# 動作確認手順

## ビルドとテスト

```bash
mise run build          # Debug（Pecha Dev）。署名 xcconfig が無ければ ad-hoc で通る
mise run build-release  # Release（Pecha）
mise run test           # Sources/Core の純粋関数（ホットキーの状態遷移・辞書の読み込み・置き換え・追記・音量・Haas の窓分け・語の戻し・pecha-model.json・frontend.json の照合）。辞書の読みの検査表は dictionary-reading: fixed= kept= known_miss= known_false_positive= を出す
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

## Haas の認識（TCC の許可が要らない）

文字起こしは Haas（iCloud Drive の `Pecha/models/` のモデル）が使えれば Haas、使えなければ OS の認識。フックも同じ選び方で、
`ENGINE` の行にどちらで認識したか（OS なら理由）が出る。**セッションの確かめでは `--model-dir` で iCloud Drive の外のコピーを指す**:
ad-hoc のビルドが iCloud Drive のファイルを読むと「“Pecha Dev.app” が “iCloud Drive” で管理されているファイルにアクセスしようとしています」が
mini の画面に出て、答えるまで止まる（Dropbox と同じ。ad-hoc はビルドのたびに出直す）。`--model-dir` のときはコンパイル先も一時フォルダになるので、
1 回ごとに Neural Engine の準備で約 80 秒かかる（mini M6）。

```bash
M=/tmp/pecha-models; mkdir -p $M
cp -cR ~/Library/Mobile\ Documents/com~apple~CloudDocs/Pecha/models/haas-ja-v1.0-int8-88d567e ~/Library/Mobile\ Documents/com~apple~CloudDocs/Pecha/models/pecha-model.json $M/
#   ↑ iCloud が中身を手元から消していると cp が取り込む（Bash からは許可の確認が出ない）
say -v Kyoko -o /tmp/names.aiff "クロードにきいてみます。なまためさんにもつたえてください。"
mise run transcribe --engine haas --model-dir $M /tmp/names.aiff
# ENGINE  haas
# RAW     クロードに聞いてみます。生田さんにも伝えてください。
# MS      haas=75 audio=4325 entries=0
```

- **予備（OS の認識に回る）**: `--model-dir` に空のフォルダ → `ENGINE os haas_unavailable …ファイルが iCloud Drive に無い`。
  `pecha-model.json` の sha256 を 1 つ書き換えたコピー → `…ファイルの中身が違う: <path>`（ログは `haas.verify_failed file=`）。
  `--engine haas` で Haas が使えなければ `ERROR` で終わる
- **手元のコンパイル済み・版の入れ替え**: `--cache-dir <dir>` でコンパイル先を固定すると、2 回目から `haas.loaded from=cache`（約 80ms）になる。
  同じ `--cache-dir` のまま、`pecha-model.json` の `version` だけ変えたコピーを `--model-dir` に渡すと、古い版を先に読み込んで Haas で動きつつ
  新しい版をコンパイルし、読み込めてから `haas.removed_old` で古い版を消す。sha256 が合わない新しい版なら、今の版のまま動く
- **認識の失敗からの予備（②）**: `bash scripts/transcribe-file.sh --model-dir $M --haas-fail error <audio>` → `ENGINE os haas_failed error`。
  `--haas-fail timeout` → 時間切れ（5 秒 + 音声の長さ × 0.25）のあと `ENGINE os haas_failed timeout`。どちらもためた音を OS の認識に通した結果が出る
- **Sanami 版との突き合わせ**: [Sanami/haas-ja-coreml](https://huggingface.co/Sanami/haas-ja-coreml) の `swift/` を `swift build -c release` して、
  okayuji 版のファイルに名前を合わせる（`encoder_T1504_w8.mlpackage` → `encoder.mlpackage` のシンボリックリンク、
  `frontend.bin` = `cat window.f32 mel_filter.f32`）。音声は先に `afconvert -f WAVE -d LEF32@16000 -c 1` で 16kHz にしてから両方に通す。
  `haas-cli <models> <res> a.wav` の `text` と、フックの `RAW` が一致する

自分の声のサンプル（iCloud Drive の `Pecha/samples/`。音声と、同じ名前の `.txt` に正しい文）を両方のエンジンで比べる。
サンプルは MacBook など**マイクのある Mac の自分の Terminal で** `mise run record-samples`（`scripts/sample-sentences.txt` の 6 本を 1 文ずつ読む。1 分ほど）で録る。
`compare` はサンプル・辞書・モデルを写してから dev 版に渡すので、セッションから回しても許可の確認で止まらない
（モデルは `~/Library/Caches/pecha-compare/models`、コンパイル先は `~/Library/Caches/pecha-compare/compiled`。初回だけ約 80 秒、以後は 1 本 1 秒ほど）。
結果の本文は画面にだけ出る（声の中身なのでファイルやリポジトリに残さない）:

```bash
mise run compare            # 各サンプルの OS / Haas の文、違う箇所の［認識→正しい］、正しい文との違い（空白と句読点を除いた文字の編集距離）、合計
```

モデルの版を入れ替えるときは `mise run place-model <okayuji 版のコミット>`（Hugging Face の値と突き合わせてから iCloud Drive に置き、
`pecha-model.json` を書き換える。古い版のフォルダは消さない）。アプリは次の起動で新しい版をコンパイルし、読み込めてから古い版を消す。

## 通常の起動（セッションから）

許可のダイアログを出さず、辞書は一時ファイルで起動して、ログで起動の流れを見る（dev 版だけの `--no-prompt` / `--dictionary`）:

起動すると Haas の準備で iCloud Drive を読みに行き、mini の画面に許可の確認が出るので、`--model-dir` で外のコピーを指す
（コンパイル先は `$TMPDIR/pecha-dev-launch-models` を使い回す。初回は約 80 秒で `haas.loaded`、2 回目からは約 70ms）:

```bash
open -g "build/Build/Products/Debug/Pecha Dev.app" --args --no-prompt --dictionary /tmp/dict.txt --model-dir /tmp/pecha-models
tail ~/Library/Logs/pecha/pecha-dev.log   # launch → menu.installed → haas.prepare → permission ax=… mic=… → dict.loaded → asr.ready → haas.loaded
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
`hotkey.down` / `hotkey.up reason=space_up|cmd_up|lost ms=` / `record.start engine=haas|os` / `record.stop reason= ms= discard= engine=` / `record.blocked reason=mic|asr_not_ready` / `record.failed error= current=` / `audio.started input=` /
`asr.assets_installing` / `asr.ready ms= format=` / `asr.prepare_failed` / `asr.session_ready ms=` / `asr.done engine=haas|os|os_fallback chars= finalize_ms= audio_ms=` / `asr.empty engine=` / `asr.failed engine=` / `asr.fallback from=haas reason=error|timeout` /
`haas.prepare reason=launch|press|hook loaded=` / `haas.model_missing path=` / `haas.downloading items=` / `haas.downloaded ms=` / `haas.download_failed` / `haas.read_failed file=` /
`haas.verified ms=` / `haas.verify_failed file=` / `haas.compiling` / `haas.compiled ms=` / `haas.loaded version= ms= from=cache|source` / `haas.load_failed reason=manifest|frontend|compile|load` /
`haas.removed_old version=` / `haas.failed reason=error|timeout` /
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

