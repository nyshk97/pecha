import AppKit

/// 録音の開始音（Funk）と終了音（Bottle）。macOS に入っている音を使う（アプリには同梱しない）。
/// 開始音はキーを押した瞬間に鳴らす（鳴らなければ「キーが届いていない」と切り分けられる）。
/// 再生は専用のキューで行う: 出力デバイスが休止していると `play()` はデバイスが起きるまで戻らず
/// （USB の Studio Display のスピーカーで約 450ms）、メインで呼ぶと録音の開始とイベントタップが待たされる
enum Sounds {
    private static let queue = DispatchQueue(label: "pecha.sound", qos: .userInteractive)
    private static let start = load("Funk")
    private static let stop = load("Bottle")

    static func playStart() { play(start) }
    static func playStop() { play(stop) }

    private static func load(_ name: String) -> NSSound? {
        let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        if sound == nil { Log.write("sound.missing name=\(name)") }
        return sound
    }

    /// `start` / `stop` の読み込みもこのキューの上で済ませる（static let は最初に触ったスレッドで作られる）
    private static func play(_ sound: @autoclosure @escaping () -> NSSound?) {
        queue.async {
            guard let sound = sound() else { return }
            // 続けて押したときは鳴っている途中から頭に戻して鳴らし直す
            sound.stop()
            sound.play()
        }
    }
}
