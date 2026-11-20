import AVFoundation

/// Haas に渡す音声（16kHz・1ch・Float32）の形式と、ためる・読む・OS の認識に回すための変換
enum HaasAudio {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(HaasLayout.sampleRate),
                                      channels: 1, interleaved: false)!

    /// 音声ファイルを 16kHz・1ch・Float32 にして読む（検証フック用）
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = BufferConverter(from: file.processingFormat, to: format) else { throw PechaError("converter") }
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
        var samples = [Float]()
        while file.framePosition < file.length {
            let count = min(chunk, AVAudioFrameCount(file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { break }
            try file.read(into: buffer, frameCount: count)
            if let out = converter.convert(buffer), let p = out.floatChannelData?[0] {
                samples += UnsafeBufferPointer(start: p, count: Int(out.frameLength))
            }
        }
        return samples
    }

    /// ためた音を OS の認識に渡す形式のバッファにする（Haas の認識に失敗したときの予備）
    static func buffers(_ samples: [Float], to output: AVAudioFormat) -> [AVAudioPCMBuffer] {
        guard let converter = BufferConverter(from: format, to: output) else { return [] }
        let chunk = HaasLayout.sampleRate / 10
        var out: [AVAudioPCMBuffer] = []
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            if let converted = converter.convert(buffer) { out.append(converted) }
            i += n
        }
        return out
    }
}

/// 押している間の音をためる。`append` は音声スレッドから、`take` は録音が止まってからメインスレッドで呼ぶ
final class SampleAccumulator {
    private let lock = NSLock()
    private var samples: [Float] = []

    init() {
        samples.reserveCapacity(HaasLayout.sampleRate * 30)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let p = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: p, count: Int(buffer.frameLength))
        lock.lock()
        samples += chunk
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }
}
