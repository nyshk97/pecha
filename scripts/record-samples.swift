// 比べる用の例文を 1 文ずつ読み上げて録音し、音声（NN.wav）と正しい文（NN.txt）を保存先に置く。
// 使い方: swift scripts/record-samples.swift <例文のファイル> [保存先]（mise run record-samples）
//   保存先の既定は iCloud Drive の Pecha/samples/（mise run compare が読む）。同じ番号のファイルは上書きする
// 自分の Terminal で動かす（マイクの許可は Terminal に付く。最初に確認が出る）
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("使い方: swift scripts/record-samples.swift <例文のファイル> [保存先]")
    exit(1)
}
guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    print("NG: \(args[1]) を読めない")
    exit(1)
}
let sentences = text.split(whereSeparator: \.isNewline)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
let dest = URL(fileURLWithPath: args.count >= 3 ? args[2]
    : NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Pecha/samples", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
} catch {
    print("NG: \(dest.path) を作れない: \(error)")
    exit(1)
}

/// 1 本ぶんの録音。マイクの入力をそのままの形式（サンプルレート・チャンネル数）で 16bit の WAV に書く
final class Take {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var peak: Float = 0
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)   // 機器の実際の形式。マイクが無いと 0ch（outputFormat は値を返してもタップで落ちる）
        guard hardware.sampleRate > 0, hardware.channelCount > 0, format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "record", code: 1, userInfo: [NSLocalizedDescriptionKey: "マイク（入力の機器）が無い"])
        }
        sampleRate = format.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? file.write(from: buffer)
            var top: Float = 0
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { top = max(top, abs(channels[c][i])) }
                }
            }
            self.lock.lock()
            self.peak = max(self.peak, top)
            self.frames += AVAudioFramePosition(buffer.frameLength)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    /// 止めてファイルを閉じる。録れた秒数と、音の大きさの最大（0〜1）を返す
    func stop() -> (seconds: Double, peak: Float) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        lock.lock()
        defer { lock.unlock() }
        return (sampleRate > 0 ? Double(frames) / sampleRate : 0, peak)
    }
}

func ask(_ prompt: String) -> String {
    print(prompt, terminator: "")
    fflush(stdout)
    guard let line = readLine() else { exit(0) }   // Ctrl+D
    return line.trimmingCharacters(in: .whitespaces).lowercased()
}

print("\(sentences.count) 本の例文を読み上げます（保存先: \(dest.path)）")
print("各文: Enter で録音を始める → 読む → Enter で止める。録り直しは r、やめるのは q\n")

var index = 0
while index < sentences.count {
    let sentence = sentences[index]
    let name = String(format: "%02d", index + 1)
    print("[\(index + 1)/\(sentences.count)] \(sentence)")
    if ask("  Enter で録音を始める ") == "q" { exit(0) }
    let wav = dest.appendingPathComponent("\(name).wav")
    let take = Take()
    do {
        try take.start(writingTo: wav)
    } catch {
        print("  NG: 録音を始められない: \(error.localizedDescription)")
        exit(1)
    }
    _ = ask("  ● 録音中… 読み終えたら Enter ")
    let (seconds, peak) = take.stop()
    print(String(format: "  %.1f 秒", seconds))
    if peak < 0.001 {
        print("  ⚠︎ 音が入っていない（システム設定 > プライバシーとセキュリティ > マイク で Terminal を許可したか、入力の機器を確かめる）。もう一度録る\n")
        continue
    }
    let answer = ask("  Enter で次へ / r で録り直す ")
    if answer == "q" {
        try? FileManager.default.removeItem(at: wav)   // 正しい文の無い音声を残さない
        exit(0)
    }
    if answer == "r" {
        print("")
        continue
    }
    do {
        try (sentence + "\n").write(to: dest.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    } catch {
        print("  NG: 正しい文を書けない: \(error)")
        exit(1)
    }
    print("")
    index += 1
}
print("終わり。\(dest.path) に \(sentences.count) 本を置いた。Claude に「録った」と伝える")
