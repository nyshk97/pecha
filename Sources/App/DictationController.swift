import AppKit
import AVFoundation

/// ホットキーの動作をつなぐ: 押している間だけ録音 → 離したら文字起こしして貼り付け / 右 ⌥ + 数字で辞書登録
///
/// 文字起こしのエンジンは押した時点で決め、離すまで変えない。Haas が使えれば押している間の音をためて、
/// 離したあとに Haas で認識する（失敗・時間切れならためた音を OS の認識に通す）。Haas が使えなければ今までどおり
/// 押している間に OS の認識へ流し、Haas の準備をやり直す
final class DictationController {
    let transcriber = Transcriber()
    let haas: HaasModel
    let recorder = Recorder()
    let hud = HUD()
    let dictionary: DictionaryStore
    private let panel = DictionaryPanel()
    private var recording: Recording?
    private var pendingReplacement: (() -> Void)?
    var onStateChange: (() -> Void)?

    var isRecording: Bool { recording != nil }

    /// 1 回の押下ぶんの録音
    private final class Recording {
        enum Engine {
            case os(TranscriptionSession)
            case haas(SampleAccumulator)
        }
        let engine: Engine
        let startedAt = CFAbsoluteTimeGetCurrent()
        init(_ engine: Engine) { self.engine = engine }

        var name: String {
            if case .haas = engine { return "haas" }
            return "os"
        }
    }

    init(dictionary: DictionaryStore, haas: HaasModel) {
        self.dictionary = dictionary
        self.haas = haas
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
        let recording: Recording
        let format: AVAudioFormat
        if haas.isReady {
            recording = Recording(.haas(SampleAccumulator()))
            format = HaasAudio.format
        } else {
            // 取り込みやコンパイルが終わっていれば、常駐したままでも次から Haas になる
            haas.prepare(reason: "press")
            guard let session = transcriber.makeSession() else {
                Log.write("record.blocked reason=asr_not_ready state=\(transcriber.state) haas=\(haas.state)")
                if case .failed = transcriber.state {
                    hud.showError("音声認識の準備に失敗しました。もう一度試します")
                } else {
                    hud.showError("音声認識を準備しています。少し待ってから押してください")
                }
                transcriber.prepare()
                return
            }
            recording = Recording(.os(session))
            format = session.format
        }
        // マイクの起動（USB のマイクで約 550ms）はメインを止めないよう Recorder のキューで待つ。
        // その間に離されたら finish が録音を止める（Recorder のキューは直列なので、起動のあとに止まる）
        self.recording = recording
        hud.showRecording()
        Log.write("record.start engine=\(recording.name)")
        onStateChange?()
        let onBuffer: (AVAudioPCMBuffer) -> Void
        switch recording.engine {
        case let .os(session): onBuffer = { session.append($0) }
        case let .haas(samples): onBuffer = { samples.append($0) }
        }
        recorder.start(format: format, onBuffer: onBuffer) { [weak self] error in
            guard let self else { return }
            let current = self.recording === recording
            if let error {
                Log.write("record.failed error=\(error) current=\(current)")
                guard current else { return }
                self.recording = nil
                if case let .os(session) = recording.engine { session.cancel() }
                self.hud.showError("録音を始められません: \(error)")
                self.onStateChange?()
                return
            }
            guard current else { return }
            // 開始音はマイクが動き出してから鳴らす（ここから話した分が録音される合図）。押した瞬間に鳴らすと、
            // 休止中のスピーカーを起こすのとマイクの起動が重なり（Studio Display は同じ USB 機器）、起動が約 400ms 延びる
            Sounds.playStart()
            self.hud.markLive()
        }
    }

    private func finish(reason: StopReason, duration: Double, discard: Bool) {
        Log.write("hotkey.up reason=\(reason.rawValue) ms=\(Int(duration * 1000))")
        guard let recording else { return }
        self.recording = nil
        hud.hide()
        Sounds.playStop()
        onStateChange?()
        Log.write("record.stop reason=\(reason.rawValue) ms=\(Log.ms(since: recording.startedAt)) discard=\(discard) engine=\(recording.name)")
        let stoppedAt = CFAbsoluteTimeGetCurrent()
        switch recording.engine {
        case let .os(session):
            recorder.stop()
            if discard {
                session.cancel()
                return
            }
            finishOS(session, stoppedAt: stoppedAt, audioMs: nil, fallback: false)
        case let .haas(samples):
            // ためた音はエンジンが止まってから取り出す（音声スレッドの書き込みとぶつからず、末尾も欠けない）
            recorder.stop { [weak self] in
                guard let self, !discard else { return }
                self.finishHaas(samples.take(), stoppedAt: stoppedAt)
            }
        }
    }

    private func finishHaas(_ samples: [Float], stoppedAt: CFAbsoluteTime) {
        let audioMs = samples.count * 1000 / HaasLayout.sampleRate
        haas.transcribe(samples) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                self.deliver(raw, engine: "haas", stoppedAt: stoppedAt, audioMs: audioMs)
            case let .failure(failure):
                // ためた音を OS の認識に通す
                Log.write("asr.fallback from=haas reason=\(failure.reason)")
                guard let session = self.transcriber.makeSession() else {
                    Log.write("asr.failed engine=os reason=asr_not_ready state=\(self.transcriber.state)")
                    self.hud.showError("文字起こしに失敗しました")
                    self.transcriber.prepare()
                    return
                }
                for buffer in HaasAudio.buffers(samples, to: session.format) { session.append(buffer) }
                self.finishOS(session, stoppedAt: stoppedAt, audioMs: audioMs, fallback: true)
            }
        }
    }

    private func finishOS(_ session: TranscriptionSession, stoppedAt: CFAbsoluteTime, audioMs: Int?, fallback: Bool) {
        Task { @MainActor in
            do {
                let raw = try await session.finish()
                self.deliver(raw, engine: fallback ? "os_fallback" : "os", stoppedAt: stoppedAt, audioMs: audioMs)
            } catch {
                Log.write("asr.failed engine=os error=\(error)")
                self.hud.showError("文字起こしに失敗しました")
            }
        }
    }

    private func deliver(_ raw: String, engine: String, stoppedAt: CFAbsoluteTime, audioMs: Int?) {
        let text = dictionary.apply(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        Log.write("asr.done engine=\(engine) chars=\(text.count) finalize_ms=\(Log.ms(since: stoppedAt))\(audioMs.map { " audio_ms=\($0)" } ?? "")")
        guard !text.isEmpty else {
            Log.write("asr.empty engine=\(engine)")
            return
        }
        Paster.pasteAndKeep(text, label: "dictation")
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
