# Pecha

KeyVoice のうち使っている機能（押している間だけ録音 → 離したら文字起こしして貼り付け、誤認識をその場で辞書に登録）だけを持つ自分用の音声入力アプリ。
兄弟アプリ `~/capit` と同じ型で作っている。Swift + AppKit + XcodeGen。`project.yml` が真実の源で `.xcodeproj` は生成物。
計画と決定の経緯は `docs/plans/`、動作確認は `VERIFY.md`。

## 固定の挙動（設定画面は作らない）

- 録音: 常用 左 ⌘ + Space / dev 右 ⌘ + Space を押している間だけ。離したら OS の音声認識（`SpeechAnalyzer` + `SpeechTranscriber`、ja_JP、`.transcription`）→ 辞書の置き換え → クリップボードに置いて合成 ⌘V（本文はクリップボードに残す。辞書登録の置き換えは元のクリップボードを戻す）。0.3 秒未満の押下は捨てる。⌘ を先に離しても止まる
- 辞書登録: 常用 右 ⌥ + 2 / dev 右 ⌥ + 3。選択テキストを取って（AX → Copy メニュー → 合成 ⌘C）パネルを出し、Enter で `dictionary.txt` の末尾に `誤 => 正` を追記、選択部分も置き換える
- 辞書: `~/Library/CloudStorage/Dropbox/settings/pecha/dictionary.txt`（dev も同じ）。録音のたびに読み直す。書き込みは追記だけ、同じ「誤」は後の行が効く。認識後の置き換えで、文字列の完全一致に加えて「誤」「正」の読みでも当てる（`Sources/Core/DictionaryFile.swift` の `replace`・`Yomi.swift`。誤爆と取りこぼしは `Tests/DictionaryReadingTests.swift` の検査表で数える。実際に出た誤認識はそこに足す）。認識時のヒント（`contextualStrings`）・カスタム言語モデル・候補は効果が無かったので使わない（plan のログ）
- ホットキーは `CGEventTap`（`.tailAppendEventTap`。keyrc が先に見られるように）。状態遷移は `Sources/Core/HotkeyMachine.swift` の純粋関数
- 効果音: マイクが動き出したとき Funk、離したとき Bottle（`/System/Library/Sounds`）。押した瞬間には HUD を灰色の点で出し、マイクが動き出したら赤にする

## コマンド

`.mise.toml` の tasks を見る。主なもの: `mise run build` / `test` / `run`（dev を /Applications に置いて起動）/ `transcribe <audio> [dictionary]` / `log` / `release`。

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
- 検証で `NSPasteboard` に書かない・ホットキーを合成しない（ユーザーのクリップボードと前面アプリを壊す）。確認は `--transcribe-file` で行う
- 合成した ⌘V / ⌘C には `eventSourceUserData` に印（`KeySynth.marker`）を付け、自分のタップの状態遷移に入れない
