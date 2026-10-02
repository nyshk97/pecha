import AppKit

/// 録音の開始音（Funk）と終了音（Bottle）。macOS に入っている音を使う（アプリには同梱しない）。
/// 開始音はキーを押した瞬間に鳴らす（鳴らなければ「キーが届いていない」と切り分けられる）
enum Sounds {
    private static let start = load("Funk")
    private static let stop = load("Bottle")

    static func playStart() { play(start) }
    static func playStop() { play(stop) }

    private static func load(_ name: String) -> NSSound? {
        let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        if sound == nil { Log.write("sound.missing name=\(name)") }
        return sound
    }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        // 続けて押したときは鳴っている途中から頭に戻して鳴らし直す
        sound.stop()
        sound.play()
    }
}
