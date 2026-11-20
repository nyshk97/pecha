import CoreML
import CryptoKit
import Foundation

/// Haas のモデルの準備と認識。
///
/// - 置き場は iCloud Drive の `Pecha/models/`（`pecha-model.json` が使う版のフォルダを指す。scripts/place-haas-model.py）
/// - 手元には版ごとのコンパイル済み（`<cacheRoot>/<版>/`）を持ち、最後に読み込めた版を `last-loaded` に書く
/// - 準備は「手元の最後に読み込めた版を読む → iCloud の json を確かめる → 版が違えば sha256 を確かめてコンパイル →
///   新しい版の読み込みが成功してから古い版を消す」。iCloud に繋がらなくても、手元のコンパイル済みがあれば使える
/// - iCloud Drive の下のファイルには準備用の専用キューでだけ触る（最初に触ったときに許可の確認で止まりうる）
/// - 認識は読み込んだモデルごとの直列キューで行い、時間切れなら使えない扱いにする（Core ML の推論は途中で止められない
///   ので、次に押したときにまた待たせない）。次の準備で手元から読み込み直す
///
/// 状態はメインスレッドで読み書きする
final class HaasModel {
    enum State: Equatable {
        case idle
        case checking
        case missing
        case downloading
        case verifyFailed(String)
        case compiling
        case loading
        case loadFailed(String)
        case timedOut
        case ready(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    /// 検証フックで予備（②）を確かめるため、認識をわざと失敗させる
    enum FailMode: String {
        case error
        case timeout
    }

    struct Failure: Error, CustomStringConvertible {
        let reason: String
        let description: String
    }

    let sourceRoot: URL
    let cacheRoot: URL
    /// 新しい版を読み込めたら古い版のコンパイル済みを消すか（検証フックの一時フォルダでは消さない）
    let deletesOldVersions: Bool
    var failMode: FailMode?

    private(set) var state: State = .idle
    private(set) var isPreparing = false
    var onStateChange: (() -> Void)?
    var isReady: Bool { state.isReady }

    private var recognizer: HaasRecognizer?
    private var inferQueue: DispatchQueue?
    private var loadedVersion: String?
    private let prepQueue = DispatchQueue(label: "pecha.haas.prepare", qos: .utility)
    private var completions: [() -> Void] = []
    private var generation = 0

    init(sourceRoot: URL, cacheRoot: URL, deletesOldVersions: Bool = true) {
        self.sourceRoot = sourceRoot
        self.cacheRoot = cacheRoot
        self.deletesOldVersions = deletesOldVersions
    }

    /// メニューバーに出す文言
    var label: String {
        switch state {
        case .ready: return "音声認識: Haas"
        case .idle, .checking: return "音声認識: OS（Haas を準備中）"
        case .missing: return "音声認識: OS（Haas のファイルが iCloud Drive に無い）"
        case .downloading: return "音声認識: OS（iCloud Drive から Haas を取り込み中）"
        case let .verifyFailed(file): return "音声認識: OS（Haas のファイルの中身が違う: \(file)）"
        case .compiling: return "音声認識: OS（Haas を準備中。初回は 1〜2 分）"
        case .loading: return "音声認識: OS（Haas を読み込み中）"
        case let .loadFailed(reason): return "音声認識: OS（Haas を読み込めない: \(reason)）"
        case .timedOut: return "音声認識: OS（Haas が時間切れ。次に押したときに読み込み直す）"
        }
    }

    /// 準備を始める（準備中なら何もしない。`completion` は準備が終わったらメインスレッドで呼ぶ）
    func prepare(reason: String, completion: (() -> Void)? = nil) {
        if let completion { completions.append(completion) }
        guard !isPreparing else { return }
        isPreparing = true
        if !isReady { set(.checking) }
        Log.write("haas.prepare reason=\(reason) loaded=\(loadedVersion ?? "none")")
        let hasRecognizer = recognizer != nil
        let loaded = loadedVersion
        prepQueue.async {
            self.runPrepare(hasRecognizer: hasRecognizer, loadedVersion: loaded)
            DispatchQueue.main.async {
                self.isPreparing = false
                if case .checking = self.state { self.set(.idle) }
                let done = self.completions
                self.completions = []
                done.forEach { $0() }
            }
        }
    }

    /// 16kHz・1ch・Float32 の音声を認識する。`completion` はメインスレッドで呼ぶ。
    /// 失敗（例外・時間切れ）のときは `Failure`（reason が error / timeout / not_ready）
    func transcribe(_ samples: [Float], completion: @escaping (Result<String, Failure>) -> Void) {
        guard isReady, let recognizer, let queue = inferQueue else {
            completion(.failure(Failure(reason: "not_ready", description: "Haas が使えない")))
            return
        }
        let audioSeconds = Double(samples.count) / Double(HaasLayout.sampleRate)
        let timeout = HaasLayout.timeout(audioSeconds: audioSeconds)
        let gen = generation
        let fail = failMode
        var finished = false
        queue.async {
            let result: Result<String, Failure>
            do {
                switch fail {
                case .error?: throw PechaError("--haas-fail error")
                case .timeout?: Thread.sleep(forTimeInterval: timeout + 1)
                case nil: break
                }
                result = .success(try recognizer.transcribe(samples).text)
            } catch {
                result = .failure(Failure(reason: "error", description: "\(error)"))
            }
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                if case let .failure(failure) = result {
                    Log.write("haas.failed reason=error error=\(failure.description)")
                }
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !finished else { return }
            finished = true
            Log.write("haas.failed reason=timeout timeout_s=\(String(format: "%.1f", timeout)) audio_ms=\(Int(audioSeconds * 1000))")
            // 詰まったモデルは捨てる（動いている推論はそのキューが握ったまま終わる）。次の準備で手元から読み込み直す
            if self.generation == gen {
                self.recognizer = nil
                self.inferQueue = nil
                self.loadedVersion = nil
                self.generation += 1
                self.set(.timedOut)
            }
            completion(.failure(Failure(reason: "timeout", description: "\(String(format: "%.1f", timeout)) 秒で返らなかった")))
        }
    }

    // MARK: - 状態

    private func set(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?()
    }

    /// 準備用のキューから呼ぶ。使える版があるあいだは、途中の状態（コンパイル中など）で上書きしない
    private func report(_ new: State) {
        DispatchQueue.main.async {
            if self.isReady && !new.isReady { return }
            self.set(new)
        }
    }

    private func adopt(_ recognizer: HaasRecognizer, version: String) {
        DispatchQueue.main.async {
            self.recognizer = recognizer
            self.inferQueue = DispatchQueue(label: "pecha.haas.infer.\(version.prefix(7)).\(self.generation)", qos: .userInitiated)
            self.loadedVersion = version
            self.generation += 1
            self.set(.ready(version))
        }
    }

    // MARK: - 準備（prepQueue の上）

    private var lastLoadedURL: URL { cacheRoot.appendingPathComponent("last-loaded") }

    private func runPrepare(hasRecognizer: Bool, loadedVersion: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        var current = loadedVersion

        // 1. 手元の最後に読み込めた版
        if !hasRecognizer {
            removeStaging()
            if let version = (try? String(contentsOf: lastLoadedURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
               !version.isEmpty, fm.fileExists(atPath: versionDir(version).path) {
                report(.loading)
                let started = CFAbsoluteTimeGetCurrent()
                do {
                    let recognizer = try HaasRecognizer(dir: versionDir(version))
                    Log.write("haas.loaded version=\(version.prefix(7)) ms=\(Log.ms(since: started)) from=cache")
                    adopt(recognizer, version: version)
                    current = version
                } catch {
                    Log.write("haas.load_failed version=\(version.prefix(7)) from=cache error=\(error)")
                    try? fm.removeItem(at: versionDir(version))
                    try? fm.removeItem(at: lastLoadedURL)
                }
            }
        }

        // 2. iCloud Drive の json
        let manifestURL = sourceRoot.appendingPathComponent("pecha-model.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            Log.write("haas.model_missing path=pecha-model.json")
            if current == nil { report(.missing) }
            return
        }
        if !waitDownloaded([manifestURL], report: current == nil) { return }
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            Log.write("haas.read_failed file=pecha-model.json error=\(error)")
            if current == nil { report(.loadFailed(Self.unreadable)) }
            return
        }
        let manifest: HaasManifest
        do {
            manifest = try HaasManifest.parse(manifestData)
        } catch {
            Log.write("haas.load_failed reason=manifest error=\(error)")
            if current == nil { report(.loadFailed("pecha-model.json を読めない")) }
            return
        }
        if manifest.version == current { return }

        // 3. 版のフォルダのファイルが手元にそろっているか
        let folder = sourceRoot.appendingPathComponent(manifest.folder, isDirectory: true)
        let urls = manifest.files.map { folder.appendingPathComponent($0.path) }
        if let absent = zip(manifest.files, urls).first(where: { !fm.fileExists(atPath: $0.1.path) }) {
            Log.write("haas.model_missing path=\(manifest.folder)/\(absent.0.path)")
            if current == nil { report(.missing) }
            return
        }
        // iCloud はパッケージ（.mlpackage）をフォルダ単位で持つので、直下のファイルとパッケージのフォルダを確かめる
        let items = Set(manifest.files.map { file -> String in
            let top = String(file.path.split(separator: "/").first ?? "")
            return top.hasSuffix(".mlpackage") ? top : file.path
        }).sorted().map { folder.appendingPathComponent($0) }
        if !waitDownloaded(items, report: current == nil) { return }

        // 4. サイズと sha256
        let verifyStarted = CFAbsoluteTimeGetCurrent()
        for (file, url) in zip(manifest.files, urls) {
            switch Self.check(url, file) {
            case .ok:
                continue
            case .mismatch:
                Log.write("haas.verify_failed file=\(file.path)")
                if current == nil { report(.verifyFailed(file.path)) }
                return
            case let .unreadable(error):
                Log.write("haas.read_failed file=\(file.path) error=\(error)")
                if current == nil { report(.loadFailed(Self.unreadable)) }
                return
            }
        }
        Log.write("haas.verified version=\(manifest.version.prefix(7)) ms=\(Log.ms(since: verifyStarted))")

        // 5. 一時フォルダにコンパイルしてから名前を変える
        report(.compiling)
        let compileStarted = CFAbsoluteTimeGetCurrent()
        Log.write("haas.compiling version=\(manifest.version.prefix(7))")
        let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let dest = versionDir(manifest.version)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in HaasManifest.packages {
                let compiled = try MLModel.compileModel(at: folder.appendingPathComponent("\(name).mlpackage"))
                try fm.moveItem(at: compiled, to: staging.appendingPathComponent("\(name).mlmodelc"))
            }
            for name in HaasManifest.resources {
                try fm.copyItem(at: folder.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            let mismatches = HaasConstants.mismatches(frontendJSON: try Data(contentsOf: staging.appendingPathComponent("frontend.json")))
            guard mismatches.isEmpty else {
                try? fm.removeItem(at: staging)
                Log.write("haas.load_failed reason=frontend version=\(manifest.version.prefix(7)) mismatches=\(mismatches.joined(separator: ","))")
                if current == nil { report(.loadFailed("frontend.json の定数がコードと違う")) }
                return
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: staging, to: dest)
        } catch {
            try? fm.removeItem(at: staging)
            Log.write("haas.load_failed reason=compile version=\(manifest.version.prefix(7)) error=\(error)")
            if current == nil { report(.loadFailed("コンパイルに失敗")) }
            return
        }
        Log.write("haas.compiled version=\(manifest.version.prefix(7)) ms=\(Log.ms(since: compileStarted))")

        // 6. 読み込み（マシンで初めてのときは Neural Engine の準備で 1 分以上かかる）
        report(.loading)
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let recognizer: HaasRecognizer
        do {
            recognizer = try HaasRecognizer(dir: dest)
        } catch {
            try? fm.removeItem(at: dest)
            Log.write("haas.load_failed reason=load version=\(manifest.version.prefix(7)) error=\(error)")
            if current == nil { report(.loadFailed("\(error)")) }
            return
        }
        try? manifest.version.write(to: lastLoadedURL, atomically: true, encoding: .utf8)
        Log.write("haas.loaded version=\(manifest.version.prefix(7)) ms=\(Log.ms(since: loadStarted)) from=source")
        adopt(recognizer, version: manifest.version)

        // 新しい版を読み込めてから古い版を消す
        if deletesOldVersions {
            let names = (try? fm.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
            for name in names where name != manifest.version && name != "last-loaded" {
                try? fm.removeItem(at: cacheRoot.appendingPathComponent(name))
                Log.write("haas.removed_old version=\(name.prefix(7))")
            }
        }
    }

    private func versionDir(_ version: String) -> URL {
        cacheRoot.appendingPathComponent(version, isDirectory: true)
    }

    private func removeStaging() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
        for name in names where name.hasPrefix(".staging-") {
            try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(name))
        }
    }

    /// iCloud が手元から消したもの（中身が無い）があれば、NSFileCoordinator で取り込む（そろうまでこのキューで待つ）。
    /// 中身は読まない: iCloud Drive の許可がまだ無いとき、中身が無いファイルを読むと確認を出さずに断られ、
    /// その判断がプロセスの間残る。取り込んで手元にそろってから最初に読むと、許可の確認が出る（答えるまで止まる）。
    /// startDownloadingUbiquitousItem も許可が無いと確認を出さずに断られる（Code=257）ので使わない。
    /// そろえば true。iCloud の外のファイルは常にそろっている扱い
    private func waitDownloaded(_ urls: [URL], report shouldReport: Bool) -> Bool {
        func pending() -> [URL] {
            urls.filter { url in
                var url = url
                url.removeAllCachedResourceValues()
                guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                      values.isUbiquitousItem == true else { return false }
                return values.ubiquitousItemDownloadingStatus != .current
            }
        }
        let waiting = pending()
        if waiting.isEmpty { return true }
        Log.write("haas.downloading items=\(waiting.count) first=\(waiting[0].lastPathComponent)")
        if shouldReport { report(.downloading) }
        let started = CFAbsoluteTimeGetCurrent()
        for url in waiting {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { _ in }
            if let error {
                Log.write("haas.download_failed item=\(url.lastPathComponent) error=\(error)")
                return false
            }
        }
        let left = pending()
        guard left.isEmpty else {
            Log.write("haas.download_failed items=\(left.count) first=\(left[0].lastPathComponent)")
            return false
        }
        Log.write("haas.downloaded ms=\(Log.ms(since: started))")
        return true
    }

    static let unreadable = "iCloud Drive のファイルを読めない（システム設定の許可を確かめる）"

    private enum Check {
        case ok
        case mismatch
        case unreadable(String)
    }

    private static func check(_ url: URL, _ file: HaasManifest.File) -> Check {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            return .unreadable("size")
        }
        guard size == file.size else { return .mismatch }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .unreadable("\(error)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        do {
            while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
                hasher.update(data: data)
                total += data.count
            }
        } catch {
            return .unreadable("\(error)")
        }
        guard total == file.size else { return .mismatch }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == file.sha256 ? .ok : .mismatch
    }
}
