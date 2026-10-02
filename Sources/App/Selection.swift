import AppKit
import ApplicationServices

/// 前面アプリの選択テキスト
struct Selection {
    let text: String
    /// AX で取れたときの入力欄（置き換えに使う）
    let element: AXUIElement?
    let via: String
}

/// 選択テキストの取得は段階フォールバック（public API で任意のアプリの選択を確実に取る方法は無い）:
/// ① `AXSelectedText`（速い・副作用なし）→ ② Copy メニューの AXPress（キーを送らない）→ ③ 合成 ⌘C。
/// ②③ はクリップボードを借りるので、貼り付けと同じやり方で元に戻す
enum SelectionReader {
    static func read(completion: @escaping (Selection?) -> Void) {
        let element = focusedElement()
        if let element, let text = string(element, kAXSelectedTextAttribute), !text.isEmpty {
            completion(Selection(text: text, element: element, via: "ax"))
            return
        }
        // AX で「選択が空」と分かるならコピーに進まない（VS Code・JetBrains 等は選択が無いと ⌘C で行全体をコピーする）
        if let element, selectedLength(element) == 0 {
            completion(nil)
            return
        }
        copyAndRead(via: "menu", trigger: pressCopyMenuItem) { text in
            if let text {
                completion(Selection(text: text, element: element, via: "menu"))
                return
            }
            copyAndRead(via: "cmd_c", trigger: { KeySynth.commandC(); return true }) { text in
                completion(text.map { Selection(text: $0, element: element, via: "cmd_c") })
            }
        }
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedLength(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.length
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// クリップボードを空にしてからコピーを起こし、changeCount が変わったら読む。最後に元に戻す
    private static func copyAndRead(via: String, trigger: () -> Bool, completion: @escaping (String?) -> Void) {
        let snapshot = Clipboard.snapshot()
        let cleared = Clipboard.clearForCopy()
        guard trigger() else {
            Clipboard.restore(snapshot, label: "selection_\(via)") { false }
            completion(nil)
            return
        }
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            ticks += 1
            let changed = Clipboard.general.changeCount != cleared
            guard changed || ticks >= 10 else { return }
            timer.invalidate()
            let copied = changed ? Clipboard.general.string(forType: .string) : nil
            Clipboard.restore(snapshot, label: "selection_\(via)") {
                // Electron 系は選択を遅れて書き戻してくる。コピーした文字列が戻ってきたら戻し直す
                copied != nil && Clipboard.general.string(forType: .string) == copied
            }
            completion(copied.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// 前面アプリのメニューから ⌘C（修飾は ⌘ だけ）の項目を探して AXPress する。
    /// 項目の `AXEnabled` はメニューを開くまで古い値なので見ない（押してみて changeCount で判定する）
    private static func pressCopyMenuItem() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        for barItem in children(bar as! AXUIElement) {
            for menu in children(barItem) {
                for item in children(menu) {
                    var char: CFTypeRef?
                    var mods: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &char)
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &mods)
                    if (char as? String) == "C", (mods as? Int) == 0 {
                        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    }
                }
            }
        }
        return false
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}

/// 選択部分を正しい語に置き換える。まず AX で `AXSelectedText` に書き込み、前後で `AXValue` を比べて
/// 変わっていなければ貼り付けに切り替える（Electron 等は書き込みが成功を返しても中身が変わらないことがある）
enum TextReplacer {
    static func replace(_ selection: Selection, with text: String) {
        if let element = selection.element,
           let before = SelectionReader.string(element, kAXValueAttribute) {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            let after = SelectionReader.string(element, kAXValueAttribute)
            if result == .success, let after, after != before {
                Log.write("dict.replaced via=ax chars=\(text.count)")
                return
            }
            Log.write("dict.replace_ax_failed result=\(result.rawValue) changed=\(after != before)")
        }
        // 空文字の ⌘V で選択が消えるかはアプリ次第なので、削除用の登録は AX が効かなければ置き換えない
        guard !text.isEmpty else {
            Log.write("dict.replace_skipped reason=empty_paste")
            return
        }
        Paster.paste(text, label: "dict_replace")
    }
}
