import Foundation

/// 辞書ファイル（既定は Dropbox の `settings/pecha/dictionary.txt`）の読み書き。
/// 録音のたびに読み直す（別の Mac で足した語がすぐ効く。監視の仕組みは持たない）。
/// 読み込みは非同期で、失敗したら前回読めた内容を使う。書き込みは末尾への追記だけ。
///
/// Dropbox（File Provider）の下のファイルに初めて触ると「“Pecha” が “Dropbox” で管理されているファイルに
/// アクセスしようとしています」の確認が出て、答えるまでその呼び出しが止まる。だからファイルには必ず専用のキューで触り、
/// メインスレッドでは触らない。起動時に読みに行くので、確認は起動直後に出る（初回に許可を求める流れ）
final class DictionaryStore {
    let url: URL
    /// 最後に読めた内容（メインスレッドで読み書きする）
    private(set) var map: [String: String] = [:]
    /// 直近の読み込みの失敗（読めたら nil。メニューに出す）
    private(set) var lastError: String?
    var onStateChange: (() -> Void)?
    private let queue = DispatchQueue(label: "pecha.dictionary")

    init(url: URL) {
        self.url = url
    }

    func reload(when: String) {
        let url = self.url
        queue.async {
            let started = CFAbsoluteTimeGetCurrent()
            let result = Self.read(url)
            DispatchQueue.main.async {
                let hadError = self.lastError != nil
                switch result {
                case let .success(map):
                    self.map = map
                    self.lastError = nil
                    if when == "launch" { Log.write("dict.loaded entries=\(map.count) ms=\(Log.ms(since: started))") }
                case let .failure(error):
                    self.lastError = error.localizedDescription
                    Log.write("dict.load_failed when=\(when) error=\(error) kept=\(self.map.count)")
                }
                if hadError != (self.lastError != nil) { self.onStateChange?() }
            }
        }
    }

    /// 検証フック用（同期）。一時ファイルを指すときだけ使う
    func reloadNow() {
        if case let .success(map) = Self.read(url) { self.map = map }
    }

    func apply(_ text: String) -> String {
        let result = DictionaryFile.replace(text, using: map)
        if result.hits > 0 { Log.write("dict.applied hits=\(result.hits)") }
        return result.text
    }

    /// ファイルが無ければ作る。あれば末尾に 1 行足す（ファイル全体は書き直さない）。
    /// `completion` はメインスレッドで呼ぶ（失敗ならエラー）
    func append(wrong: String, right: String, completion: @escaping (Error?) -> Void) {
        let url = self.url
        queue.async {
            let error: Error?
            do {
                try Self.append(wrong: wrong, right: right, to: url)
                error = nil
            } catch let e {
                error = e
            }
            DispatchQueue.main.async {
                if let error {
                    Log.write("dict.add_failed error=\(error)")
                } else {
                    self.map[DictionaryFile.normalize(wrong)] = DictionaryFile.normalize(right)
                    Log.write("dict.add wrong_chars=\(wrong.count) right_chars=\(right.count) entries=\(self.map.count)")
                }
                completion(error)
            }
        }
    }

    /// 無ければヘッダだけのファイルを作ってから `then` を呼ぶ（メニューの「辞書ファイルを開く」用）
    func ensureExists(then: @escaping () -> Void) {
        let url = self.url
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(Self.header.utf8).write(to: url)
            }
            DispatchQueue.main.async(execute: then)
        }
    }

    static let header = """
    # Pecha の辞書。1 行 1 件「誤 => 正」。# で始まる行はコメント。
    # 同じ「誤」が複数あれば後の行が効く。誤認識を選択して辞書登録のキーを押すと末尾に追記される。

    """

    private static func append(wrong: String, right: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try Data(header.utf8).write(to: url)
            Log.write("dict.created")
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var endsWithNewline = true
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            endsWithNewline = try handle.read(upToCount: 1) == Data("\n".utf8)
            try handle.seekToEnd()
        }
        let line = DictionaryFile.appendLine(wrong: wrong, right: right, existingEndsWithNewline: endsWithNewline)
        try handle.write(contentsOf: Data(line.utf8))
    }

    private static func read(_ url: URL) -> Result<[String: String], Error> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success([:]) }
        do {
            return .success(DictionaryFile.parse(try String(contentsOf: url, encoding: .utf8)))
        } catch {
            return .failure(error)
        }
    }
}
