import AppKit

/// 辞書登録のパネル（誤: 選択部分 / 正: 入力欄）。
/// `.nonactivatingPanel` で key にだけなる（元のアプリは前面のままで選択も残り、日本語入力も使える）。
/// Enter で登録、Esc・外をクリックで取り消し。日本語入力の変換中の Enter では確定させない
final class DictionaryPanel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: KeyPanel
    private let wrongField = NSTextField()
    private let rightField = NSTextField()
    private let message = NSTextField(labelWithString: "")
    private var onSubmit: ((String, String, @escaping (String?) -> Void) -> Void)?
    private var submitting = false
    private var onClose: (() -> Void)?
    private var closing = false

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        let title = NSTextField(labelWithString: "辞書に登録")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let wrongLabel = NSTextField(labelWithString: "誤")
        let rightLabel = NSTextField(labelWithString: "正")
        for field in [wrongField, rightField] {
            field.font = .systemFont(ofSize: 15)
            field.delegate = self
            field.bezelStyle = .roundedBezel
            field.lineBreakMode = .byTruncatingTail
            field.cell?.isScrollable = true
            field.cell?.wraps = false
        }
        wrongField.placeholderString = "誤認識された語"
        rightField.placeholderString = "正しい語"
        wrongField.nextKeyView = rightField
        rightField.nextKeyView = wrongField
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor

        for v in [title, wrongLabel, rightLabel, wrongField, rightField, message] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        let pad: CGFloat = 16
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: pad),
            wrongLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: pad),
            wrongLabel.centerYAnchor.constraint(equalTo: wrongField.centerYAnchor),
            wrongLabel.widthAnchor.constraint(equalToConstant: 18),
            wrongField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            wrongField.leadingAnchor.constraint(equalTo: wrongLabel.trailingAnchor, constant: 6),
            wrongField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -pad),
            rightLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: pad),
            rightLabel.centerYAnchor.constraint(equalTo: rightField.centerYAnchor),
            rightLabel.widthAnchor.constraint(equalToConstant: 18),
            rightField.topAnchor.constraint(equalTo: wrongField.bottomAnchor, constant: 8),
            rightField.leadingAnchor.constraint(equalTo: rightLabel.trailingAnchor, constant: 6),
            rightField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -pad),
            message.topAnchor.constraint(equalTo: rightField.bottomAnchor, constant: 10),
            message.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: pad),
            message.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -pad),
        ])
    }

    /// `onSubmit` は結果を completion で返す。エラー文ならパネルは開いたまま、nil なら閉じる
    /// （辞書は Dropbox にあり書き込みがすぐ終わるとは限らないので、非同期で受ける）
    func open(wrong: String, onSubmit: @escaping (String, String, @escaping (String?) -> Void) -> Void, onClose: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onClose = onClose
        closing = false
        submitting = false
        wrongField.stringValue = wrong
        rightField.stringValue = wrong
        message.stringValue = "Enter で登録 / Esc で取り消し"
        message.textColor = .secondaryLabelColor
        let frame = NSScreen.underMouse.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY + frame.height * 0.12))
        panel.makeKeyAndOrderFront(nil)
        // 選択が無ければ「誤」から、あれば「正」を全選択した状態から打てるようにする
        let first = wrong.isEmpty ? wrongField : rightField
        panel.makeFirstResponder(first)
        first.currentEditor()?.selectAll(nil)
        Log.write("dict.panel_opened wrong_chars=\(wrong.count) key=\(panel.isKeyWindow)")
    }

    func close(reason: String) {
        guard !closing, panel.isVisible else { return }
        closing = true
        panel.orderOut(nil)
        Log.write("dict.panel_closed reason=\(reason)")
        onClose?()
        onClose = nil
        onSubmit = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // 変換中の Enter は入力メソッドが先に取るが、念のため未確定の文字があれば何もしない
            if textView.hasMarkedText() { return false }
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(reason: "escape")
            return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close(reason: "lost_focus")
    }

    private func submit() {
        guard let onSubmit, !submitting else { return }
        submitting = true
        message.stringValue = "登録しています…"
        message.textColor = .secondaryLabelColor
        onSubmit(wrongField.stringValue, rightField.stringValue) { [weak self] error in
            guard let self, !self.closing else { return }
            self.submitting = false
            if let error {
                self.message.stringValue = error
                self.message.textColor = .systemRed
                return
            }
            self.close(reason: "submitted")
        }
    }
}
