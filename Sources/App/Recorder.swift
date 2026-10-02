import AVFoundation

/// マイクの録音。押下のたびに AVAudioEngine を作り直す（入力デバイスの切り替え・スリープ復帰で
/// エンジンが黙って止まるのを避けるため。常時は動かさないので、メニューバーのマイク表示も録音中だけ出る）
final class Recorder {
    private var engine: AVAudioEngine?
    /// HUD に出す音量（0〜1）。メインスレッドで呼ぶ
    var onLevel: ((Float) -> Void)?

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        guard permission == .notDetermined else {
            completion(permission == .authorized)
            return
        }
        Log.write("mic.requesting")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.write("mic.answered granted=\(granted)")
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// `onBuffer` は音声スレッドから呼ばれる（認識に渡す形式に変換済み）
    func start(format: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw PechaError("入力デバイスが無い") }
        guard let converter = BufferConverter(from: inputFormat, to: format) else { throw PechaError("音声の変換を作れない") }
        var lastLevelAt: CFAbsoluteTime = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            if let out = converter.convert(buffer) { onBuffer(out) }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLevelAt > 0.05, let channel = buffer.floatChannelData?[0] {
                lastLevelAt = now
                let level = Level.normalized(rms: Level.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
                DispatchQueue.main.async { self?.onLevel?(level) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        Log.write("audio.started input=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch")
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
