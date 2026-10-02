import AppKit

/// ホットキーの動作をつなぐ: 押している間だけ録音 → 離したら文字起こしして貼り付け / 右 ⌥ + 数字で辞書登録
final class DictationController {
    let transcriber = Transcriber()
    let recorder = Recorder()
    let hud = HUD()
    let dictionary: DictionaryStore
    private let panel = DictionaryPanel()
    private var session: TranscriptionSession?
    private var recordStartedAt: CFAbsoluteTime = 0
    private var pendingReplacement: (() -> Void)?
    var onStateChange: (() -> Void)?

    var isRecording: Bool { session != nil }

    init(dictionary: DictionaryStore) {
        self.dictionary = dictionary
        recorder.onLevel = { [weak self] level in self?.hud.setLevel(level) }
    }

    func handle(_ action: HotkeyAction) {
        switch action {
        case .startRecording:
            start()
        case let .finishRecording(reason, duration, discard):
            finish(reason: reason, duration: duration, discard: discard)
        case .dictionary:
            openDictionary()
        }
    }

    // MARK: - 録音 → 文字起こし → 貼り付け

    private func start() {
        // 押した瞬間に鳴らす（鳴らなければキーが届いていない、と切り分けられる）
        Sounds.playStart()
        Log.write("hotkey.down")
        dictionary.reload(when: "press")
        guard Recorder.permission == .authorized else {
            Log.write("record.blocked reason=mic permission=\(Recorder.permission.rawValue)")
            if Recorder.permission == .notDetermined {
                hud.showError("マイクの許可を確認しています。許可してからもう一度押してください")
                Recorder.requestPermissionIfNeeded { [weak self] _ in self?.onStateChange?() }
            } else {
                hud.showError("マイクの許可がありません（メニューバーの Pecha から設定を開けます）")
            }
            return
        }
        guard let session = transcriber.makeSession() else {
            Log.write("record.blocked reason=asr_not_ready state=\(transcriber.state)")
            if case .failed = transcriber.state {
                hud.showError("音声認識の準備に失敗しました。もう一度試します")
            } else {
                hud.showError("音声認識を準備しています。少し待ってから押してください")
            }
            transcriber.prepare()
            return
        }
        do {
            try recorder.start(format: session.format) { buffer in session.append(buffer) }
        } catch {
            session.cancel()
            Log.write("record.failed error=\(error)")
            hud.showError("録音を始められません: \(error)")
            return
        }
        self.session = session
        recordStartedAt = CFAbsoluteTimeGetCurrent()
        hud.showRecording()
        Log.write("record.start")
        onStateChange?()
    }

    private func finish(reason: StopReason, duration: Double, discard: Bool) {
        Log.write("hotkey.up reason=\(reason.rawValue) ms=\(Int(duration * 1000))")
        guard let session else { return }
        self.session = nil
        recorder.stop()
        hud.hide()
        Sounds.playStop()
        onStateChange?()
        Log.write("record.stop reason=\(reason.rawValue) ms=\(Log.ms(since: recordStartedAt)) discard=\(discard)")
        if discard {
            session.cancel()
            return
        }
        let stoppedAt = CFAbsoluteTimeGetCurrent()
        Task { @MainActor in
            do {
                let raw = try await session.finish()
                let text = self.dictionary.apply(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                Log.write("asr.done chars=\(text.count) finalize_ms=\(Log.ms(since: stoppedAt))")
                guard !text.isEmpty else {
                    Log.write("asr.empty")
                    return
                }
                Paster.pasteAndKeep(text, label: "dictation")
            } catch {
                Log.write("asr.failed error=\(error)")
                self.hud.showError("文字起こしに失敗しました")
            }
        }
    }

    // MARK: - 辞書登録

    private func openDictionary() {
        Log.write("hotkey.dictionary")
        if panel.isOpen {
            panel.close(reason: "toggle")
            return
        }
        SelectionReader.read { [weak self] selection in
            guard let self else { return }
            Log.write("dict.selection via=\(selection?.via ?? "none") chars=\(selection?.text.count ?? 0)")
            let shown = selection.map { DictionaryFile.normalize($0.text) } ?? ""
            self.panel.open(wrong: shown, onSubmit: { wrong, right, done in
                self.register(wrong: wrong, right: right, selection: selection, completion: done)
            }, onClose: {
                // パネルが閉じて元のアプリにキーが戻ってから置き換える
                guard let replace = self.pendingReplacement else { return }
                self.pendingReplacement = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: replace)
            })
        }
    }

    /// 登録できなければエラー文を completion に返す
    private func register(wrong: String, right: String, selection: Selection?, completion: @escaping (String?) -> Void) {
        if let error = DictionaryFile.validate(wrong: wrong, right: right) {
            completion(error)
            return
        }
        dictionary.append(wrong: wrong, right: right) { [weak self] error in
            if let error {
                completion("辞書に書き込めませんでした: \(error.localizedDescription)")
                return
            }
            if let self, let selection {
                let entry = [DictionaryFile.normalize(wrong): DictionaryFile.normalize(right)]
                let replaced = DictionaryFile.replace(selection.text, using: entry)
                if selection.via != "ax", selection.text.hasSuffix("\n") {
                    // コピーで取れた行全体（選択が無いときの行コピー）。カーソル位置に貼ると行が重複する
                    Log.write("dict.replace_skipped reason=line_copy")
                } else if replaced.hits > 0 {
                    self.pendingReplacement = { TextReplacer.replace(selection, with: replaced.text) }
                } else {
                    Log.write("dict.replace_skipped reason=no_match")
                }
            }
            completion(nil)
        }
    }
}
