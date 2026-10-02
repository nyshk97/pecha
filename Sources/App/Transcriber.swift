import AVFoundation
import Speech

/// OS の音声認識（SpeechAnalyzer + SpeechTranscriber、ja_JP）。起動時にモデルの準備を済ませ、
/// 押下のたびにセッションを作る（作成から準備完了まで約 100ms。その間に来た音声は AsyncStream が溜める）
final class Transcriber {
    enum State: Equatable {
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .preparing
    /// 認識に渡す形式（ja_JP では 16kHz / 1ch / Int16）
    private(set) var format: AVAudioFormat?
    var onStateChange: (() -> Void)?
    private var preparing = false

    /// 失敗していたら次の押下でもう一度呼ぶ
    func prepare() {
        guard !preparing, state != .ready else { return }
        preparing = true
        state = .preparing
        let started = CFAbsoluteTimeGetCurrent()
        Task {
            let result: State
            let format: AVAudioFormat?
            do {
                let prepared = try await Self.prepareAssets()
                format = prepared
                result = .ready
                Log.write("asr.ready ms=\(Log.ms(since: started)) format=\(Int(prepared.sampleRate))Hz/\(prepared.channelCount)ch")
            } catch {
                format = nil
                result = .failed("\(error)")
                Log.write("asr.prepare_failed error=\(error)")
            }
            await MainActor.run {
                self.format = format
                self.state = result
                self.preparing = false
                self.onStateChange?()
            }
        }
    }

    private static func prepareAssets() async throws -> AVAudioFormat {
        guard SpeechTranscriber.isAvailable else { throw PechaError("SpeechTranscriber が使えない") }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: Env.locale) != nil else {
            throw PechaError("ja_JP に対応していない")
        }
        let module = SpeechTranscriber(locale: Env.locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.write("asr.assets_installing")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw PechaError("認識に渡す音声の形式が決まらない")
        }
        return format
    }

    func makeSession() -> TranscriptionSession? {
        guard state == .ready, let format else { return nil }
        return TranscriptionSession(format: format)
    }
}

/// 1 回の押下ぶんの認識。`append` で音声を流し込み、`finish` で確定させて全文を得る
final class TranscriptionSession {
    let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let setup: Task<(SpeechAnalyzer, Task<String, Error>), Error>
    let createdAt = CFAbsoluteTimeGetCurrent()

    init(format: AVAudioFormat) {
        self.format = format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let created = createdAt
        setup = Task {
            let module = SpeechTranscriber(locale: Env.locale, preset: .transcription)
            // モデルをプロセスの間ずっと載せておく（押下のたびの読み込みを避ける）
            let analyzer = SpeechAnalyzer(modules: [module],
                                          options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            let collector = Task { () -> String in
                var text = ""
                for try await result in module.results { text += String(result.text.characters) }
                return text
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
            Log.write("asr.session_ready ms=\(Log.ms(since: created))")
            return (analyzer, collector)
        }
    }

    /// 音声スレッドから呼んでよい
    func append(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> String {
        continuation.finish()
        let (analyzer, collector) = try await setup.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    func cancel() {
        continuation.finish()
        let setup = self.setup
        Task {
            guard let (analyzer, collector) = try? await setup.value else { return }
            await analyzer.cancelAndFinishNow()
            collector.cancel()
        }
    }
}

/// 入力（マイク・音声ファイル）の形式を認識に渡す形式へ変換する
final class BufferConverter {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

struct PechaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
