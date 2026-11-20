import Foundation

/// iCloud Drive の `Pecha/models/pecha-model.json`（scripts/place-haas-model.py が書く）。
/// どの版を使うかと、その版のフォルダの全ファイルのサイズ・sha256
struct HaasManifest: Codable, Equatable {
    struct File: Codable, Equatable {
        let path: String
        let size: Int
        let sha256: String
    }

    let version: String
    let folder: String
    let files: [File]

    /// コンパイルする Core ML のパッケージ（フォルダの中の名前）
    static let packages = ["encoder", "decoder", "joint_enc", "joint"]
    /// パッケージのほかに手元へ写すファイル
    static let resources = ["vocab.json", "window.f32", "mel_filter.f32", "frontend.json"]

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ data: Data) throws -> HaasManifest {
        let manifest = try JSONDecoder().decode(HaasManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    /// 手元のフォルダ名に使うので、版とフォルダ名に区切り文字が入っていないこと、要るファイルがそろっていることを確かめる
    func validate() throws {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        for (name, value) in [("version", version), ("folder", folder)] {
            guard !value.isEmpty, !value.hasPrefix("."), value.unicodeScalars.allSatisfy(safe.contains) else {
                throw Invalid(description: "\(name) が不正: \(value)")
            }
        }
        let paths = Set(files.map(\.path))
        for name in Self.resources where !paths.contains(name) {
            throw Invalid(description: "\(name) が無い")
        }
        for name in Self.packages where !paths.contains("\(name).mlpackage/Manifest.json") {
            throw Invalid(description: "\(name).mlpackage が無い")
        }
        for file in files where file.path.hasPrefix("/") || file.path.split(separator: "/").contains("..") {
            throw Invalid(description: "パスが不正: \(file.path)")
        }
    }
}

/// okayuji 版の frontend.json の定数が、このコード（HaasFrontend・HaasLayout）の前提と同じかを確かめる。
/// 版を入れ替えたときに前処理やデコードの定数が変わっていると、エラーにならずに精度だけ落ちるため
enum HaasConstants {
    /// 食い違った項目の一覧（空なら一致）
    static func mismatches(frontendJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["frontend.json を読めない"]
        }
        let expected: [(String, Any)] = [
            ("audio.sample_rate", HaasLayout.sampleRate),
            ("audio.channels", 1),
            ("frontend.preemph", 0.97),
            ("frontend.n_fft", HaasFrontend.nFFT),
            ("frontend.win_length", HaasFrontend.winLength),
            ("frontend.hop_length", HaasFrontend.hop),
            ("frontend.n_mels", HaasFrontend.nMels),
            ("frontend.stft.bins", HaasFrontend.nBins),
            ("frontend.stft.center", true),
            ("frontend.log.zero_guard_value", pow(2.0, -24.0)),
            ("frontend.normalize.eps", 1e-5),
            ("encoder.window_frames", HaasLayout.window),
            ("encoder.output_frames", HaasLayout.encFrames),
            ("encoder.subsampling", HaasLayout.sub),
            ("long_audio.window_frames", HaasLayout.window),
            ("long_audio.dropped_frames_each_inner_edge", HaasLayout.context),
            ("long_audio.boundary_multiple", HaasLayout.sub),
            ("decoding.blank_id", HaasLayout.blank),
            ("decoding.durations", HaasLayout.durations),
            ("decoding.max_symbols", HaasLayout.maxSymbols),
            ("decoder_state.first_token", HaasLayout.blank),
            ("vocab.size", HaasLayout.vocabSize),
        ]
        var out: [String] = []
        for (path, want) in expected {
            let got = value(at: path, in: root)
            if !same(got, want) { out.append("\(path)=\(got.map { "\($0)" } ?? "なし")") }
        }
        return out
    }

    private static func value(at path: String, in root: [String: Any]) -> Any? {
        var node: Any? = root
        for key in path.split(separator: ".") {
            node = (node as? [String: Any])?[String(key)]
        }
        return node
    }

    private static func same(_ got: Any?, _ want: Any) -> Bool {
        switch want {
        case let w as Bool:
            return (got as? Bool) == w
        case let w as Int:
            guard let g = got as? NSNumber, CFGetTypeID(g) != CFBooleanGetTypeID() else { return false }
            return g.doubleValue == Double(w)
        case let w as Double:
            guard let g = got as? NSNumber, CFGetTypeID(g) != CFBooleanGetTypeID() else { return false }
            return abs(g.doubleValue - w) <= abs(w) * 1e-9
        case let w as [Int]:
            guard let g = got as? [NSNumber] else { return false }
            return g.map(\.doubleValue) == w.map(Double.init)
        default:
            return false
        }
    }
}
