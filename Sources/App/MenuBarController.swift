import AppKit

/// メニューバーの小さなアイコン（設定画面は作らない）。録音中・異常はアイコンの見た目にも出す
final class MenuBarController: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private let statusItem: NSStatusItem

    init(app: AppDelegate) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
        Log.write("menu.installed")
    }

    /// 異常があれば文言を返す（メニューに出し、アイコンを警告にする）
    private var warnings: [(String, Selector?)] {
        var list: [(String, Selector?)] = []
        if !app.hotkeys.isTrusted {
            list.append(("⚠︎ アクセシビリティの許可がありません（ホットキーが効きません）", #selector(openAccessibility(_:))))
        } else if !app.hotkeys.isRunning {
            list.append(("⚠︎ ホットキーの監視を始められません（ログを見てください）", nil))
        }
        if Recorder.permission == .denied || Recorder.permission == .restricted {
            list.append(("⚠︎ マイクの許可がありません", #selector(openMicrophone(_:))))
        }
        if case let .failed(message) = app.controller.transcriber.state {
            list.append(("⚠︎ 音声認識の準備に失敗しました: \(message)", nil))
        }
        if let error = app.controller.dictionary.lastError {
            // Dropbox へのアクセスを「許可しない」にしたときもここに出る
            list.append(("⚠︎ 辞書ファイルを読めません: \(error)", nil))
        }
        return list
    }

    func refresh() {
        let button = statusItem.button
        if app.controller.isRecording {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Pecha 録音中")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            image?.isTemplate = false
            button?.image = image
        } else if !warnings.isEmpty {
            button?.image = template("exclamationmark.triangle")
        } else if app.hotkeys.isSecureInput {
            button?.image = template("lock.fill")
        } else {
            button?.image = template("waveform")
        }
    }

    private func template(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Pecha")
        image?.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let record = NSMenuItem(title: "録音: \(Env.recordLabel) を押している間", action: nil, keyEquivalent: "")
        record.isEnabled = false
        menu.addItem(record)
        let dict = NSMenuItem(title: "辞書に登録: 誤認識を選択して \(Env.dictionaryLabel)", action: nil, keyEquivalent: "")
        dict.isEnabled = false
        menu.addItem(dict)

        var notes = warnings
        if app.hotkeys.isSecureInput {
            notes.append(("🔒 セキュア入力が ON の間はホットキーが届きません（パスワード欄など）", nil))
        }
        if case .preparing = app.controller.transcriber.state {
            notes.append(("音声認識を準備しています…", nil))
        }
        if !notes.isEmpty {
            menu.addItem(.separator())
            for (text, action) in notes {
                let item = NSMenuItem(title: text, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = action != nil
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "辞書ファイルを開く", action: #selector(openDictionary(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let version = NSMenuItem(title: Env.versionLabel, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let about = NSMenuItem(title: "Pecha について", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        #if !DEBUG
        let update = NSMenuItem(title: "アップデートを確認…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        update.target = self
        update.isEnabled = app.canCheckForUpdates
        menu.addItem(update)
        #endif
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func openDictionary(_ sender: Any?) {
        let dictionary = app.controller.dictionary
        dictionary.ensureExists {
            NSWorkspace.shared.open(dictionary.url)
            Log.write("menu.open_dictionary")
        }
    }

    @objc private func openAccessibility(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophone(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func showAbout(_ sender: Any?) { app.showAbout() }
    #if !DEBUG
    @objc private func checkForUpdates(_ sender: Any?) { app.checkForUpdates() }
    #endif
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
