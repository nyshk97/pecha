import AppKit
import AVFoundation
import ServiceManagement
#if !DEBUG
import Sparkle
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: DictationController!
    private(set) var hotkeys: HotkeyMonitor!
    private var menuBar: MenuBarController!

    #if !DEBUG
    private var updaterController: SPUStandardUpdaterController?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }

        #if DEBUG
        if let i = args.firstIndex(of: "--transcribe-file"), i + 1 < args.count {
            runTranscribeHook(audio: args[i + 1], dictionary: value(after: "--dictionary", in: args))
            return
        }
        #endif

        if let other = otherInstance() {
            Log.write("launch.already_running pid=\(other)")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        Log.write("launch pid=\(ProcessInfo.processInfo.processIdentifier) version=\(Env.version) dev=\(Env.isDev) record=\(Env.recordLabel) dictionary=\(Env.dictionaryLabel)")

        var dictionaryURL = Env.sharedDictionaryURL
        #if DEBUG
        // dev 版だけ通常の起動でも辞書を差し替えられる（セッションから起動を確かめるとき、Dropbox の確認を出さないため）
        if let path = value(after: "--dictionary", in: args) { dictionaryURL = URL(fileURLWithPath: path) }
        #endif
        let dictionary = DictionaryStore(url: dictionaryURL)
        dictionary.reload(when: "launch")
        controller = DictationController(dictionary: dictionary)
        hotkeys = HotkeyMonitor { [weak self] action in self?.controller.handle(action) }
        menuBar = MenuBarController(app: self)
        hotkeys.onStateChange = { [weak self] in self?.menuBar.refresh() }
        controller.onStateChange = { [weak self] in self?.menuBar.refresh() }
        controller.transcriber.onStateChange = { [weak self] in self?.menuBar.refresh() }
        dictionary.onStateChange = { [weak self] in self?.menuBar.refresh() }
        controller.transcriber.prepare()
        hotkeys.start()

        // dev 版だけ `--no-prompt` で許可のダイアログを出さない（AI のセッションから起動を確かめるとき）
        var prompt = true
        #if DEBUG
        prompt = !args.contains("--no-prompt")
        #endif
        Log.write("permission ax=\(AXIsProcessTrusted()) mic=\(Recorder.permission.rawValue) prompt=\(prompt)")
        if prompt {
            if !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            Recorder.requestPermissionIfNeeded { [weak self] _ in self?.menuBar.refresh() }
        }

        #if !DEBUG
        startUpdater()
        registerLoginItem()
        #endif
    }

    private func otherInstance() -> pid_t? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me }?.processIdentifier
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - メニューから呼ぶ

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "Version \(Env.version)",
            .version: "",
        ])
    }

    #if !DEBUG
    var canCheckForUpdates: Bool { updaterController != nil }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// SUPublicEDKey が未設定のまま Sparkle を起動すると起動時にエラーダイアログが出るので、そのときは起動しない
    private func startUpdater() {
        let key = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("__") else {
            Log.write("update.disabled reason=no_public_key")
            return
        }
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        Log.write("update.started")
    }

    /// 常用版だけ、初回起動時にログイン項目へ登録する（dev 版はログイン時に起動しない）
    private func registerLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            break
        case .requiresApproval:
            Log.write("login_item.requires_approval")
        default:
            do {
                try SMAppService.mainApp.register()
                Log.write("login_item.registered")
            } catch {
                Log.write("login_item.register_failed \(error)")
            }
        }
    }
    #endif

    // MARK: - 検証フック（dev 版のみ）

    #if DEBUG
    /// `--transcribe-file <audio> [--dictionary <path>]`: 音声ファイルを実機能と同じ `Transcriber` と辞書の置き換えに通し、
    /// 結果の本文を stdout に出して終了する（ログには文字数だけ）。マイク・ホットキーを使わないので TCC の許可が要らない。
    /// タップ・メニューバー・ログイン登録は立てない。`--dictionary` を省くと辞書は空（共有の辞書は読み書きしない）。
    /// 起動は `open -n -g -W --stdout <file> "Pecha Dev.app" --args ...`（scripts/transcribe-file.sh）
    private func runTranscribeHook(audio: String, dictionary: String?) {
        Log.write("hook.transcribe dictionary=\(dictionary == nil ? "none" : "file")")
        // メインスレッドが止まっても（ファイルの許可の確認待ち等）効くよう、見張りは別のキューに置く
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            Self.emit("ERROR\ttimeout")
            exit(2)
        }
        let transcriber = Transcriber()
        transcriber.onStateChange = {
            switch transcriber.state {
            case .ready:
                Task { @MainActor in await Self.transcribe(audio: audio, dictionary: dictionary, transcriber: transcriber) }
            case let .failed(message):
                Self.emit("ERROR\tasr \(message)")
                exit(1)
            case .preparing:
                break
            }
        }
        transcriber.prepare()
    }

    @MainActor
    private static func transcribe(audio: String, dictionary: String?, transcriber: Transcriber) async {
        do {
            guard let session = transcriber.makeSession() else { throw PechaError("session") }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: audio))
            guard let converter = BufferConverter(from: file.processingFormat, to: session.format) else { throw PechaError("converter") }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
            while file.framePosition < file.length {
                let count = min(chunk, AVAudioFrameCount(file.length - file.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { break }
                try file.read(into: buffer, frameCount: count)
                if let out = converter.convert(buffer) { session.append(out) }
            }
            let fed = CFAbsoluteTimeGetCurrent()
            let raw = try await session.finish()
            let store = DictionaryStore(url: URL(fileURLWithPath: dictionary ?? "/dev/null"))
            if dictionary != nil { store.reloadNow() }
            let text = store.apply(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("asr.done chars=\(text.count) finalize_ms=\(Log.ms(since: fed)) via=hook")
            emit("RAW\t\(raw)")
            emit("TEXT\t\(text)")
            emit("MS\tsession=\(Log.ms(since: session.createdAt)) finalize=\(Log.ms(since: fed)) entries=\(store.map.count)")
            exit(0)
        } catch {
            emit("ERROR\t\(error)")
            exit(1)
        }
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
        Log.flush()
    }
    #endif
}
