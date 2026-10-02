import AppKit

extension NSScreen {
    /// マウスのある画面（`NSScreen.main` は常駐アプリだと key window が無くて当てにならない）
    static var underMouse: NSScreen {
        let point = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(point) } ?? main ?? screens[0]
    }
}

/// 録音中の表示（マウスのある画面の下の方に、録音中のマークと音量だけ）。エラーもここに短く出す。
/// フルスクリーンのアプリの上にも出し、マウスのイベントは受けない
final class HUD {
    private let panel: NSPanel
    private let dot = NSView()
    private let meter = LevelMeterView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        for v in [dot, meter, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
            meter.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            meter.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            meter.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            meter.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
    }

    func showRecording() {
        hideWork?.cancel()
        meter.level = 0
        meter.isHidden = false
        label.isHidden = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        place(width: 140)
        panel.orderFrontRegardless()
    }

    func setLevel(_ level: Float) {
        meter.level = CGFloat(level)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    func showError(_ message: String) {
        hideWork?.cancel()
        meter.isHidden = true
        label.isHidden = false
        label.stringValue = message
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        let width = min(520, ceil(label.intrinsicContentSize.width) + 56)
        place(width: width)
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func place(width: CGFloat) {
        let frame = NSScreen.underMouse.visibleFrame
        let size = NSSize(width: width, height: 40)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 80, width: size.width, height: size.height), display: true)
    }
}

/// 音量のバー（中央から上下に伸びる縦棒を並べる）
final class LevelMeterView: NSView {
    private var history = [CGFloat](repeating: 0, count: 14)

    var level: CGFloat = 0 {
        didSet {
            history.removeFirst()
            history.append(level)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = CGFloat(history.count)
        let gap: CGFloat = 3
        let barWidth = max(2, (bounds.width - gap * (count - 1)) / count)
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        for (i, value) in history.enumerated() {
            let h = max(2, bounds.height * value)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
