import AppKit
import Carbon
import CoreGraphics

/// グローバルホットキーを CGEventTap で取る（⌘ + Space と右 ⌥ + 数字を前面アプリに届かないように飲み込むため）。
///
/// 「押しても反応しない」への備え:
/// - `kCGEventTapDisabledByTimeout` / `ByUserInput` を受けたら即座に再有効化する
/// - 監視タイマーで `tapIsEnabled` を見る（タップが黙って止まるのが典型的な原因）。止まっている間に keyUp を
///   取りこぼしたときは、物理キーの状態から録音を止める
/// - アクセシビリティの許可が無い間はタイマーで待ち、許可が出たらタップを作る
/// - セキュア入力（パスワード欄など）が ON の間はキーが一切届かないので、ログとアイコンに出す
///
/// タップは `.tailAppendEventTap` で作る（keyrc のタップが先に Space を見られるように。keyrc は左 ⌘ の単独タップで
/// 「英数」を送り、途中の keyDown で取り消す作りなので、Pecha が先に Space を飲むと入力ソースが英字に変わる）。
/// コールバックは判定だけにして、処理は非同期で投げる（遅いと DisabledByTimeout になる）
final class HotkeyMonitor {
    private var machine = HotkeyMachine(config: Env.hotkeys)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private let onAction: (HotkeyAction) -> Void
    var onStateChange: (() -> Void)?

    /// タップが止まっていた・スリープから戻った（keyUp を取りこぼしたかもしれない）
    private var needsReconcile = false
    private var loggedCreateFailure = false
    private(set) var isTrusted = false
    private(set) var isSecureInput = false
    var isRunning: Bool { tap != nil }

    init(onAction: @escaping (HotkeyAction) -> Void) {
        self.onAction = onAction
    }

    func start() {
        check(reason: "launch")
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check(reason: "watchdog") }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("system.woke")
            self?.check(reason: "wake")
        }
    }

    private func check(reason: String) {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            Log.write("ax.trusted value=\(trusted) when=\(reason)")
            // 許可を取り消されたタップは再有効化しても効かないので捨て、許可が戻ったら作り直す
            if !trusted { destroyTap() }
            onStateChange?()
        }
        if tap == nil, trusted { createTap() }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            needsReconcile = true
            Log.write("tap.reenabled reason=\(reason)")
        }
        if reason == "wake" { needsReconcile = true }
        let secure = IsSecureEventInputEnabled()
        if secure != isSecureInput {
            isSecureInput = secure
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
            Log.write("secure_input.\(secure ? "on" : "off") front=\(app)")
            needsReconcile = true
            onStateChange?()
        }
        // 録音中は毎回照合する（keyUp だけ届かないと録音が続き、次の押下も飲まれて反応しなくなる）。
        // 照合は物理キーが上がっているときしか止めないので、押している最中の録音は止まらない
        if needsReconcile || machine.isRecording {
            needsReconcile = false
            reconcile()
        }
    }

    /// keyUp を取りこぼしていたら（タップが止まっていた等）、物理キーの状態に合わせて録音を止める。
    /// 物理キーの状態はタップの影響を受けない hidSystemState で読み、⌘ は左右を問わないビットで見る
    private func reconcile() {
        let state = CGEventSourceStateID.hidSystemState
        let space = CGEventSource.keyState(state, key: CGKeyCode(KeyCodes.space))
        let flags = CGEventSource.flagsState(state).rawValue
        let command = flags & FlagBits.command != 0
        let dictKey = CGEventSource.keyState(state, key: CGKeyCode(Env.hotkeys.dictionaryKeyCode))
        if let action = machine.reconcile(spaceDown: space, commandDown: command, dictionaryKeyDown: dictKey,
                                          at: ProcessInfo.processInfo.systemUptime) {
            onAction(action)
        }
    }

    private func createTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            if !loggedCreateFailure { Log.write("tap.create_failed") }
            loggedCreateFailure = true
            return
        }
        loggedCreateFailure = false
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("tap.created record=\(Env.recordLabel) dictionary=\(Env.dictionaryLabel)")
        onStateChange?()
    }

    private func destroyTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        Log.write("tap.destroyed reason=ax_revoked")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            needsReconcile = true
            Log.write("tap.reenabled reason=\(type == .tapDisabledByTimeout ? "timeout" : "user_input")")
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        // 自分が合成した ⌘V / ⌘C は状態遷移に入れない
        if KeySynth.isOwn(event) { return Unmanaged.passUnretained(event) }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let keyEvent: KeyEvent
        switch type {
        case .keyDown: keyEvent = .keyDown(keyCode: keyCode, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: flags)
        case .keyUp: keyEvent = .keyUp(keyCode: keyCode, flags: flags)
        default: keyEvent = .flagsChanged(keyCode: keyCode, flags: flags)
        }
        // event.timestamp は Apple Silicon で単位が ns と限らないので、reconcile と同じ時計で測る
        let decision = machine.handle(keyEvent, at: ProcessInfo.processInfo.systemUptime)
        if let action = decision.action {
            DispatchQueue.main.async { [onAction] in onAction(action) }
        }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
