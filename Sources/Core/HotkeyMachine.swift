import Foundation

/// CGEventFlags の生の値。左右の修飾キーは機種依存ビット（NX_DEVICE*KEYMASK）で見分ける
/// （`maskCommand` 等には左右の情報が無い）
enum FlagBits {
    static let shift: UInt64 = 0x0002_0000
    static let control: UInt64 = 0x0004_0000
    static let option: UInt64 = 0x0008_0000
    static let command: UInt64 = 0x0010_0000

    static let leftCommand: UInt64 = 0x08
    static let rightCommand: UInt64 = 0x10
    static let leftOption: UInt64 = 0x20
    static let rightOption: UInt64 = 0x40
}

enum KeyCodes {
    static let space = 49
    static let ansi2 = 19
    static let ansi3 = 20
    static let c = 8
    static let v = 9
    static let leftCommand = 55
}

/// イベントタップから状態遷移に渡すキーイベント（Pecha 自身が合成したイベントは渡す前に除く）
enum KeyEvent: Equatable {
    case keyDown(keyCode: Int, isRepeat: Bool, flags: UInt64)
    case keyUp(keyCode: Int, flags: UInt64)
    case flagsChanged(keyCode: Int, flags: UInt64)
}

enum StopReason: String, Equatable {
    /// Space を離した
    case spaceUp = "space_up"
    /// ⌘ を先に離した
    case commandUp = "cmd_up"
    /// keyUp を取りこぼした（タップが止まっていた等）。実際のキーの状態を見て止めた
    case lost
}

enum HotkeyAction: Equatable {
    case startRecording
    /// `discard` は短すぎる押下（録音を捨てる）
    case finishRecording(reason: StopReason, duration: Double, discard: Bool)
    case dictionary
}

struct HotkeyDecision: Equatable {
    /// true ならイベントを前面アプリに届けない
    var swallow: Bool
    var action: HotkeyAction?

    static let pass = HotkeyDecision(swallow: false, action: nil)
}

struct HotkeyConfig: Equatable {
    /// 録音を始める ⌘ の機種依存ビット（常用は左、dev は右）
    var recordCommand: UInt64
    /// 辞書登録のキー（常用は 2、dev は 3）。右 ⌥ と組み合わせる
    var dictionaryKeyCode: Int
}

/// 「⌘ + Space を押している間だけ録音」と「右 ⌥ + 数字で辞書登録」の状態遷移。
/// イベントタップのコールバックから呼ぶので、判定だけをして重い処理はしない（呼び出し側が非同期で投げる）
struct HotkeyMachine {
    /// これより短い押下は録音を捨てる
    static let minimumDuration: Double = 0.3

    let config: HotkeyConfig
    /// 録音を始めた時刻（録音中でなければ nil）
    private(set) var recordingSince: Double?
    /// 録音を始めた Space の keyUp まで、Space（リピートを含む）を飲み込む。
    /// ⌘ を先に離して録音が止まっても、Space のリピートが前面アプリに漏れないようにする
    private(set) var swallowingSpace = false
    private var swallowingDictionaryKey = false

    init(config: HotkeyConfig) {
        self.config = config
    }

    var isRecording: Bool { recordingSince != nil }

    mutating func handle(_ event: KeyEvent, at time: Double) -> HotkeyDecision {
        switch event {
        case let .keyDown(keyCode, isRepeat, flags) where keyCode == KeyCodes.space:
            if swallowingSpace {
                // リピートでない keyDown は keyUp を取りこぼしたあと。録音中でなければ新しい押下として見直す
                if isRepeat || isRecording { return HotkeyDecision(swallow: true, action: nil) }
                swallowingSpace = false
            }
            guard !isRepeat, isRecordChord(flags) else { return .pass }
            recordingSince = time
            swallowingSpace = true
            return HotkeyDecision(swallow: true, action: .startRecording)

        case let .keyUp(keyCode, _) where keyCode == KeyCodes.space:
            guard swallowingSpace else { return .pass }
            swallowingSpace = false
            return HotkeyDecision(swallow: true, action: finish(.spaceUp, at: time))

        case let .flagsChanged(_, flags):
            // ⌘ を先に離したら録音を止める。修飾キーのイベント自体は前面アプリに届ける
            if isRecording, flags & config.recordCommand == 0 {
                return HotkeyDecision(swallow: false, action: finish(.commandUp, at: time))
            }
            return .pass

        case let .keyDown(keyCode, isRepeat, flags) where keyCode == config.dictionaryKeyCode:
            if swallowingDictionaryKey { return HotkeyDecision(swallow: true, action: nil) }
            guard !isRepeat, isDictionaryChord(flags) else { return .pass }
            swallowingDictionaryKey = true
            return HotkeyDecision(swallow: true, action: .dictionary)

        case let .keyUp(keyCode, _) where keyCode == config.dictionaryKeyCode:
            guard swallowingDictionaryKey else { return .pass }
            swallowingDictionaryKey = false
            return HotkeyDecision(swallow: true, action: nil)

        default:
            return .pass
        }
    }

    /// keyUp を取りこぼしたとき（タップが OS に止められていた等）、実際のキーの状態から録音を止める。
    /// 引数は呼び出し側が物理キーの状態を読んで渡す
    mutating func reconcile(spaceDown: Bool, commandDown: Bool, dictionaryKeyDown: Bool, at time: Double) -> HotkeyAction? {
        if !spaceDown { swallowingSpace = false }
        if !dictionaryKeyDown { swallowingDictionaryKey = false }
        guard isRecording, !spaceDown || !commandDown else { return nil }
        return finish(.lost, at: time)
    }

    private mutating func finish(_ reason: StopReason, at time: Double) -> HotkeyAction? {
        guard let since = recordingSince else { return nil }
        recordingSince = nil
        let duration = max(0, time - since)
        return .finishRecording(reason: reason, duration: duration, discard: duration < Self.minimumDuration)
    }

    private func isRecordChord(_ flags: UInt64) -> Bool {
        flags & config.recordCommand != 0 && flags & (FlagBits.shift | FlagBits.control | FlagBits.option) == 0
    }

    private func isDictionaryChord(_ flags: UInt64) -> Bool {
        flags & FlagBits.rightOption != 0 && flags & (FlagBits.shift | FlagBits.control | FlagBits.command) == 0
    }
}
