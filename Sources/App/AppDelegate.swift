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
            runTranscribeHook(audio: args[i + 1], dictionary: value(after: "--dictionary", in: args),
                              engine: value(after: "--engine", in: args), modelDir: value(after: "--model-dir", in: args),
                              failMode: value(after: "--haas-fail", in: args), cacheDir: value(after: "--cache-dir", in: args))
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
        var haas = HaasModel(sourceRoot: Env.haasSourceRoot, cacheRoot: Env.haasCacheRoot)
        #if DEBUG
        // dev 版だけ `--model-dir` でモデルの置き場を差し替えられる（セッションから起動を確かめるとき、iCloud Drive の確認を出さないため）。
        // コンパイル先も一時フォルダ（決まった名前で使い回す。pkill で止めても溜まらない）にして、dev 版のコンパイル済みを読んだり消したりしない
        if let path = value(after: "--model-dir", in: args) {
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("pecha-dev-launch-models", isDirectory: true)
            haas = HaasModel(sourceRoot: URL(fileURLWithPath: path, isDirectory: true), cacheRoot: cache)
        }
        #endif
        controller = DictationController(dictionary: dictionary, haas: haas)
        hotkeys = HotkeyMonitor { [weak self] action in self?.controller.handle(action) }
        menuBar = MenuBarController(app: self)
        hotkeys.onStateChange = { [weak self] in self?.menuBar.refresh() }
        controller.onStateChange = { [weak self] in self?.menuBar.refresh() }
        controller.transcriber.onStateChange = { [weak self] in self?.menuBar.refresh() }
        dictionary.onStateChange = { [weak self] in self?.menuBar.refresh() }
        haas.onStateChange = { [weak self] in self?.menuBar.refresh() }
        controller.transcriber.prepare()
        haas.prepare(reason: "launch")
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
    /// `--transcribe-file <audio> [--dictionary <path>] [--engine haas|os] [--model-dir <path>] [--haas-fail error|timeout]`:
    /// 音声ファイルを実機能と同じ認識と辞書の置き換えに通し、結果の本文を stdout に出して終了する（ログには文字数だけ）。
    /// マイク・ホットキーを使わないので TCC の許可が要らない。タップ・メニューバー・ログイン登録は立てない。
    /// - `--dictionary` を省くと辞書は空（共有の辞書は読み書きしない）
    /// - `--engine` を省くとアプリと同じ選び方（Haas の準備が終わってから、使えれば Haas、使えなければ OS）。
    ///   `haas` で Haas が使えなければエラーで終える。`os` なら Haas の準備をしない
    /// - `--model-dir` は iCloud Drive の `Pecha/models/` と同じ形のフォルダ。そのときはコンパイル先も一時フォルダにして、
    ///   dev 版のコンパイル済みを読んだり消したりしない
    /// - `--cache-dir` はコンパイル先を指す（`--model-dir` と組み合わせて、手元のコンパイル済みを先に読む経路・版の入れ替えを確かめる）
    /// - `--haas-fail` は Haas の認識をわざと失敗させる（失敗したら OS の認識に回る予備を確かめる）
    /// 出力: `ENGINE`（haas / os と、OS になった理由）・`RAW`（認識そのまま）・`TEXT`（辞書の置き換え後）・`MS`（時間）。
    /// 起動は `open -n -g -W --stdout <file> "Pecha Dev.app" --args ...`（scripts/transcribe-file.sh）
    private func runTranscribeHook(audio: String, dictionary: String?, engine: String?, modelDir: String?, failMode: String?,
                                   cacheDir: String?) {
        Log.write("hook.transcribe dictionary=\(dictionary == nil ? "none" : "file") engine=\(engine ?? "auto") model_dir=\(modelDir == nil ? "icloud" : "custom") fail=\(failMode ?? "none")")
        if let engine, engine != "haas", engine != "os" { Self.fail("--engine は haas か os") }
        let fail: HaasModel.FailMode?
        if let failMode {
            guard let mode = HaasModel.FailMode(rawValue: failMode) else { Self.fail("--haas-fail は error か timeout") }
            fail = mode
        } else {
            fail = nil
        }
        // メインスレッドが止まっても（ファイルの許可の確認待ち等）効くよう、見張りは別のキューに置く。
        // Haas はマシンで初めてのとき、sha256・コンパイル・Neural Engine の準備で 1〜2 分かかる（mini で約 80 秒）
        let limit: Double = engine == "os" ? 60 : 300
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            Self.emit("ERROR\ttimeout \(Int(limit))s")
            exit(2)
        }
        let samples: [Float]
        do {
            samples = try HaasAudio.load(URL(fileURLWithPath: audio))
        } catch {
            Self.fail("音声を読めない: \(error)")
        }
        let store = DictionaryStore(url: URL(fileURLWithPath: dictionary ?? "/dev/null"))
        if dictionary != nil { store.reloadNow() }
        let transcriber = Transcriber()
        transcriber.prepare()

        func runOS(reason: String, fromSamples: Bool) {
            Self.whenReady(transcriber) {
                Task { @MainActor in
                    do {
                        let (raw, ms) = try await Self.transcribeOS(audio: audio, samples: fromSamples ? samples : nil, transcriber: transcriber)
                        Self.finish(raw: raw, engine: "os\t\(reason)", ms: ms, store: store)
                    } catch {
                        Self.fail("os \(error)")
                    }
                }
            }
        }
        if engine == "os" {
            runOS(reason: "requested", fromSamples: false)
            return
        }
        var cacheRoot = Env.haasCacheRoot
        var sourceRoot = Env.haasSourceRoot
        if let modelDir {
            sourceRoot = URL(fileURLWithPath: modelDir, isDirectory: true)
            if cacheDir == nil {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pecha-hook-\(UUID().uuidString)", isDirectory: true)
                cacheRoot = temp
                atexit_b { try? FileManager.default.removeItem(at: temp) }
            }
        }
        if let cacheDir { cacheRoot = URL(fileURLWithPath: cacheDir, isDirectory: true) }
        let haas = HaasModel(sourceRoot: sourceRoot, cacheRoot: cacheRoot, deletesOldVersions: modelDir == nil || cacheDir != nil)
        haas.failMode = fail
        haas.prepare(reason: "hook") {
            guard haas.isReady else {
                if engine == "haas" { Self.fail("haas \(haas.label)") }
                runOS(reason: "haas_unavailable \(haas.label)", fromSamples: false)
                return
            }
            let started = CFAbsoluteTimeGetCurrent()
            haas.transcribe(samples) { result in
                switch result {
                case let .success(raw):
                    Self.finish(raw: raw, engine: "haas", ms: "haas=\(Log.ms(since: started)) audio=\(samples.count * 1000 / HaasLayout.sampleRate)", store: store)
                case let .failure(failure):
                    Log.write("asr.fallback from=haas reason=\(failure.reason) via=hook")
                    runOS(reason: "haas_failed \(failure.reason)", fromSamples: true)
                }
            }
        }
    }

    private static func whenReady(_ transcriber: Transcriber, _ body: @escaping () -> Void) {
        switch transcriber.state {
        case .ready:
            body()
        case let .failed(message):
            fail("asr \(message)")
        case .preparing:
            transcriber.onStateChange = { whenReady(transcriber, body) }
        }
    }

    /// `samples` があればそれを（Haas の失敗からの予備と同じ経路）、無ければファイルを直接 OS の形式に変えて流す
    @MainActor
    private static func transcribeOS(audio: String, samples: [Float]?, transcriber: Transcriber) async throws -> (String, String) {
        guard let session = transcriber.makeSession() else { throw PechaError("session") }
        if let samples {
            for buffer in HaasAudio.buffers(samples, to: session.format) { session.append(buffer) }
        } else {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: audio))
            guard let converter = BufferConverter(from: file.processingFormat, to: session.format) else { throw PechaError("converter") }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
            while file.framePosition < file.length {
                let count = min(chunk, AVAudioFrameCount(file.length - file.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { break }
                try file.read(into: buffer, frameCount: count)
                if let out = converter.convert(buffer) { session.append(out) }
            }
        }
        let fed = CFAbsoluteTimeGetCurrent()
        let raw = try await session.finish()
        return (raw, "session=\(Log.ms(since: session.createdAt)) finalize=\(Log.ms(since: fed))")
    }

    private static func finish(raw: String, engine: String, ms: String, store: DictionaryStore) {
        let text = store.apply(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        Log.write("asr.done engine=\(engine.split(separator: "\t").first ?? "") chars=\(text.count) via=hook")
        emit("ENGINE\t\(engine)")
        emit("RAW\t\(raw)")
        emit("TEXT\t\(text)")
        emit("MS\t\(ms) entries=\(store.map.count)")
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        emit("ERROR\t\(message)")
        exit(1)
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
        Log.flush()
    }
    #endif
}
