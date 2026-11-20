# Pecha

KeyVoice のうち使っている機能（押している間だけ録音 → 離したら文字起こしして貼り付け、誤認識をその場で辞書に登録）だけを持つ自分用の音声入力アプリ。
兄弟アプリ `~/capit` と同じ型で作っている。Swift + AppKit + XcodeGen。`project.yml` が真実の源で `.xcodeproj` は生成物。
計画と決定の経緯は `docs/plans/`、動作確認は `VERIFY.md`。

## 固定の挙動（設定画面は作らない）

- 録音: 常用 左 ⌘ + Space / dev 右 ⌘ + Space を押している間だけ。離したら文字起こし → 辞書の置き換え → クリップボードに置いて合成 ⌘V（本文はクリップボードに残す。辞書登録の置き換えは元のクリップボードを戻す）。0.3 秒未満の押下は捨てる。⌘ を先に離しても止まる
- 文字起こし: 日本語の音声認識モデル Haas-ja-v1.0（Core ML・INT8。okayuji 版を版 `88d567e` に決めて、新しい版は追いかけない）。押した時点でエンジンを決め、Haas が使えれば押している間の音（16kHz・1ch・Float32）をためて、離したあとに認識する。Haas が使えない（モデルが無い・取り込み中・コンパイル中・読み込みに失敗・時間切れのあと）ときは OS の音声認識（`SpeechAnalyzer` + `SpeechTranscriber`、ja_JP、`.transcription`）に押している間に流す。Haas の認識が失敗・時間切れなら、ためた音を OS の認識に通す。どちらで認識したかはメニューに出る。計画と経緯は `docs/plans/2026-11-20-1355-haas音声認識への乗り換え.md`
- Haas のモデル: iCloud Drive の `Pecha/models/`（`pecha-model.json` が使う版のフォルダと全ファイルの sha256 を指す。`mise run place-model <版>` で置く）。各 Mac で一度だけ確かめてコンパイルし、`~/Library/Application Support/<bundle id>/models/<版>/` に持つ。起動時はまず手元のコンパイル済みを読み、iCloud の json は後から確かめる。推論コードは Sanami/haas-ja-coreml の Swift 版を写したもの（`ThirdParty/haas-ja-coreml/`）
- 辞書登録: 常用 右 ⌥ + 2 / dev 右 ⌥ + 3。選択テキストを取って（AX → Copy メニュー → 合成 ⌘C）パネルを出し、Enter で `dictionary.txt` の末尾に `誤 => 正` を追記、選択部分も置き換える
- 辞書: `~/Library/CloudStorage/Dropbox/settings/pecha/dictionary.txt`（dev も同じ）。録音のたびに読み直す。書き込みは追記だけ、同じ「誤」は後の行が効く。認識後の置き換えで、文字列の完全一致に加えて「誤」「正」の読みでも当てる（`Sources/Core/DictionaryFile.swift` の `replace`・`Yomi.swift`。誤爆と取りこぼしは `Tests/DictionaryReadingTests.swift` の検査表で数える。実際に出た誤認識はそこに足す）。認識時のヒント（`contextualStrings`）・カスタム言語モデル・候補は効果が無かったので使わない（plan のログ）
- ホットキーは `CGEventTap`（`.tailAppendEventTap`。keyrc が先に見られるように）。状態遷移は `Sources/Core/HotkeyMachine.swift` の純粋関数
- 効果音: マイクが動き出したとき Funk、離したとき Bottle（`/System/Library/Sounds`）。押した瞬間には HUD を灰色の点で出し、マイクが動き出したら赤にする

## コマンド

`.mise.toml` の tasks を見る。主なもの: `mise run build` / `test` / `run`（dev を /Applications に置いて起動）/ `transcribe [--engine haas|os] [--model-dir <dir>] <audio> [dictionary]` / `record-samples`（比べる用の例文を読み上げて録る。マイクのある Mac の自分の Terminal で）/ `compare`（録ったサンプルを両方のエンジンで比べる）/ `place-model <版>`（Haas のモデルを iCloud Drive に置く）/ `log` / `release`。

## 会社貸与 PC での制約

会社貸与 PC（判定はグローバルの CLAUDE.md）では Claude Code のセッションから keychain に触らない。
`mise run signing`（証明書の解決）・`mise run release`・`generate_keys` / `sign_update` はユーザーが自分の Terminal で叩く。
セッション（環境変数 `CLAUDECODE` が立っている）からの `mise run build` / `build-release` / `test` は ad-hoc 署名になり、`scripts/make-release-zip.sh` は ad-hoc で再署名して zip の手前で止まる。
ad-hoc はリビルドごとにマイク・アクセシビリティ・Dropbox の許可が外れるので、セッションの検証は `--transcribe-file` のフックとログで済ませる。

## 構成

- `Sources/Core/` — 純粋関数（テスト対象。テストはアプリをホストにせずこのディレクトリだけをコンパイルする）
- `Sources/App/` — 起動・単一インスタンス・イベントタップ・録音・認識・貼り付け・辞書パネル・メニューバー

## 罠

- Dropbox（File Provider）の下のファイルに初めて触ると TCC の確認が出て、答えるまでその呼び出しが止まる。辞書のファイルにはメインスレッドで触らない（`DictionaryStore` の専用キュー）
- iCloud Drive も同じ（「“Pecha Dev.app” が “iCloud Drive” で管理されているファイルにアクセスしようとしています」）。Haas のモデルには `HaasModel` の準備用のキューでだけ触る。さらに、**許可がまだ無いとき、iCloud が中身を手元から消したファイル（`ls -lO` で `dataless`）を読む・`startDownloadingUbiquitousItem` を呼ぶと、確認を出さずに Code=257 で断られる**。中身が無いものは `NSFileCoordinator` で取り込んでから読む（取り込みの段階で確認が出る）。アプリ自身が作ったファイルは確認なしで読み書きできるので、確認を出させる用途には使えない（2026-11-20、mini で確認）
- セッションの検証で ad-hoc のビルドに iCloud Drive を読ませない（mini の画面に確認が出て止まる）。フックは `--model-dir` で外のコピーを指す。誤って出した確認に「許可しない」で答えたら `tccutil reset FileProviderDomain io.github.nyshk97.pecha.dev` で未決定に戻す（答えはビルドが変わっても bundle id に残り、以後は確認なしで断られる）
- Bash・Python から iCloud が中身を手元から消したファイルを読むと `EDEADLK`（Resource deadlock avoided）で断られる。`brctl download <ファイル>` で取り込んでから読む（フォルダを渡しても中まで降りないので 1 つずつ。`find <dir> -flags +dataless` で探せる）。mini はディスクの空きが少なく、置いた直後に小さなファイルから消される
- Haas はマシンで初めて読み込むとき（コンパイル済みの置き場が変わったときも）、Neural Engine の準備で約 80 秒かかる（mini M6・macOS 27.0.1。公開されている数字は約 10 秒）。その間は OS の認識で動く。2 回目からは 0.1 秒
- 検証で `NSPasteboard` に書かない・ホットキーを合成しない（ユーザーのクリップボードと前面アプリを壊す）。確認は `--transcribe-file` で行う
- 合成した ⌘V / ⌘C には `eventSourceUserData` に印（`KeySynth.marker`）を付け、自分のタップの状態遷移に入れない
- dev版がホットキーに反応しない（ログが`permission ax=false`のままで`tap.created`が無い）ときは、`codesign -dvv "/Applications/Pecha Dev.app"`で`Signature=adhoc`になっていないかを見る。新しいMacでは`mise run signing`を自分のTerminalで一度実行するまでad-hocのまま。ad-hocのビルドでは、システム設定でONに見えても前のビルドへの許可なので、「−」で消してから許可し直す。許可が効いてから`ax.trusted value=true`が出るまで十数秒かかる
