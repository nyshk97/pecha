import AppKit

/// クリップボードを一時的に借りて元に戻す。
/// 元の内容は全部の item の全部の type を取っておく（文字列だけだと画像・ファイルが壊れる）
enum Clipboard {
    /// クリップボード管理アプリに「一時的な内容なので記録しない」と伝える印（nspasteboard.org の取り決め）
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    struct Snapshot {
        let items: [[(NSPasteboard.PasteboardType, Data)]]
    }

    static var general: NSPasteboard { .general }

    static func snapshot() -> Snapshot {
        let items = (general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        return Snapshot(items: items)
    }

    /// 一時的な内容を置き、その時点の changeCount を返す
    @discardableResult
    static func putTransient(_ text: String) -> Int {
        general.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        general.writeObjects([item])
        return general.changeCount
    }

    /// 普通のコピーとして置く（クリップボード管理アプリの履歴にも残る）
    static func put(_ text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }

    static func clearForCopy() -> Int {
        general.clearContents()
        return general.changeCount
    }

    /// 元に戻す。そのあと約 1 秒、Electron 系が数百 ms 遅れて書き戻してきたら（`shouldReRestore` が true なら）戻し直す
    static func restore(_ snapshot: Snapshot, label: String, shouldReRestore: @escaping () -> Bool) {
        write(snapshot)
        var restoredCount = general.changeCount
        var rewrites = 0
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            ticks += 1
            if general.changeCount != restoredCount {
                if shouldReRestore() {
                    write(snapshot)
                    restoredCount = general.changeCount
                    rewrites += 1
                } else {
                    // ユーザーが別のものをコピーした。以後は触らない
                    timer.invalidate()
                    Log.write("clipboard.restored what=\(label) rewrites=\(rewrites) stopped=user_copy")
                    return
                }
            }
            if ticks >= 10 {
                timer.invalidate()
                Log.write("clipboard.restored what=\(label) rewrites=\(rewrites)")
            }
        }
    }

    private static func write(_ snapshot: Snapshot) {
        general.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { general.writeObjects(items) }
    }
}

/// クリップボード経由で前面アプリに貼り付ける
enum Paster {
    /// 貼り付けて、本文をクリップボードに残す（貼り先に入力欄が無くても ⌘V でもう一度貼れる）
    static func pasteAndKeep(_ text: String, label: String) {
        Clipboard.put(text)
        KeySynth.commandV()
        Log.write("paste.done what=\(label) chars=\(text.count) kept=1")
    }

    /// 貼り付けて、元のクリップボードを戻す
    static func paste(_ text: String, label: String) {
        let snapshot = Clipboard.snapshot()
        let ours = Clipboard.putTransient(text)
        KeySynth.commandV()
        Log.write("paste.done what=\(label) chars=\(text.count)")
        // 貼り付け先がクリップボードを読み終わるのを待ってから戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard Clipboard.general.changeCount == ours else {
                Log.write("clipboard.restore_skipped what=\(label) reason=changed")
                return
            }
            Clipboard.restore(snapshot, label: label) {
                // 置いた本文が書き戻されてきたときだけ戻し直す
                Clipboard.general.types?.contains(Clipboard.transientType) == true
            }
        }
    }
}
