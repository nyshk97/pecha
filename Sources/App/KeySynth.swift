import CoreGraphics

/// 前面アプリへ合成の ⌘V / ⌘C を送る。
/// 修飾は `flagsChanged` で送る（keyDown に `.maskCommand` を付けるだけだとターミナル・Electron で素の文字が漏れる）。
/// 自分のイベントタップで取り違えないよう `eventSourceUserData` に印を付ける
/// （貼り付けの ⌘ の解放を「⌘ を先に離した」と読むと、次の録音が止まる）
enum KeySynth {
    /// "PECH"
    static let marker: Int64 = 0x5045_4348

    static func commandV() { commandKey(KeyCodes.v) }
    static func commandC() { commandKey(KeyCodes.c) }

    static func isOwn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    private static func commandKey(_ keyCode: Int) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = marker
        // 送っている間に物理キーが割り込まないようにする
        source.setLocalEventsFilterDuringSuppressionState([], state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0.05
        let command = CGEventFlags(rawValue: FlagBits.command | FlagBits.leftCommand)
        let cmd = CGKeyCode(KeyCodes.leftCommand)
        let key = CGKeyCode(keyCode)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false) else { return }
        cmdDown.type = .flagsChanged
        cmdDown.flags = command
        keyDown.flags = command
        keyUp.flags = command
        cmdUp.type = .flagsChanged
        cmdUp.flags = []
        // 物理の ⌘ が押されたまま（Space だけ離して続けて口述する）なら ⌘ の解放は送らない。
        // 送るとセッションの修飾状態から ⌘ が落ち、次の Space に ⌘ が付かず録音が始まらない
        let held = CGEventSource.flagsState(.hidSystemState).rawValue & FlagBits.command != 0
        for event in held ? [cmdDown, keyDown, keyUp] : [cmdDown, keyDown, keyUp, cmdUp] {
            event.post(tap: .cghidEventTap)
        }
    }
}
