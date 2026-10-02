import Foundation

/// dev 版（Pecha Dev）と常用版で変わる値をまとめる
enum Env {
    #if DEBUG
    static let isDev = true
    static let logFileName = "pecha-dev.log"
    /// dev 版は常用版・KeyVoice と並行して動かせるよう別のキー（右 ⌘ + Space / 右 ⌥ + 3）
    static let hotkeys = HotkeyConfig(recordCommand: FlagBits.rightCommand, dictionaryKeyCode: KeyCodes.ansi3)
    static let recordLabel = "右⌘ + Space"
    static let dictionaryLabel = "右⌥ + 3"
    #else
    static let isDev = false
    static let logFileName = "pecha.log"
    static let hotkeys = HotkeyConfig(recordCommand: FlagBits.leftCommand, dictionaryKeyCode: KeyCodes.ansi2)
    static let recordLabel = "左⌘ + Space"
    static let dictionaryLabel = "右⌥ + 2"
    #endif

    static let locale = Locale(identifier: "ja_JP")

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var versionLabel: String {
        isDev ? "Pecha v\(version) (dev)" : "Pecha v\(version)"
    }

    /// 全部の Mac で共有する辞書（Dropbox）。dev 版も同じものを使う（検証フックは --dictionary で一時ファイルを指す）
    static let sharedDictionaryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage/Dropbox/settings/pecha/dictionary.txt")

    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/pecha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(logFileName)
    }()
}
