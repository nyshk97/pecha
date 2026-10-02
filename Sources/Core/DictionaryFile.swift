import Foundation

/// 辞書ファイル（`dictionary.txt`）の書式と置き換え。ファイルの読み書きは App 側（DictionaryStore）
///
/// 書式: 1 行 1 件 `誤 => 正`。`#` 始まりはコメント。`=>` の無い行・空行は無視し、前後の空白は落とす。
/// 同じ「誤」が複数あれば後の行を採用する（書き込みは末尾への追記だけなので、後の行が新しい）
enum DictionaryFile {
    static let separator = "=>"

    static func parse(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let range = line.range(of: separator) else { continue }
            let wrong = normalize(String(line[..<range.lowerBound]))
            let right = normalize(String(line[range.upperBound...]))
            if wrong.isEmpty { continue }
            map[wrong] = right
        }
        return map
    }

    /// 1 回の走査で、左から最長一致で置き換える。置き換えた部分には二度と当てないので、
    /// `A => B` と `B => C` があっても A が C になる連鎖は起きない
    static func replace(_ text: String, using map: [String: String]) -> (text: String, hits: Int) {
        guard !map.isEmpty else { return (text, 0) }
        let keys = map.keys.map { Array($0) }.sorted { $0.count > $1.count }
        let chars = Array(normalize(text, trimming: false))
        var out = ""
        var hits = 0
        var i = 0
        while i < chars.count {
            if let key = keys.first(where: { matches($0, in: chars, at: i) }) {
                out += map[String(key)] ?? ""
                hits += 1
                i += key.count
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return (out, hits)
    }

    /// 追記する 1 行（末尾の改行込み）。`existingEndsWithNewline` が false なら先頭に改行を補う
    /// （手で編集して最後の行に改行が無いと、追記した行が前の行につながって 2 件とも壊れる）
    static func appendLine(wrong: String, right: String, existingEndsWithNewline: Bool) -> String {
        let line = "\(normalize(wrong)) \(separator) \(normalize(right))\n"
        return existingEndsWithNewline ? line : "\n" + line
    }

    /// 登録できない組なら理由を返す
    static func validate(wrong: String, right: String) -> String? {
        let w = normalize(wrong)
        let r = normalize(right)
        if w.isEmpty { return "誤認識の語が空です" }
        if w.hasPrefix("#") { return "「#」で始まる語は登録できません（コメントになります）" }
        if w.contains(separator) || r.contains(separator) { return "「\(separator)」を含む語は登録できません" }
        if w == r { return "誤と正が同じです" }
        return nil
    }

    /// 改行は空白にし（1 行 1 件を壊さない）、合成済みの形にそろえる
    static func normalize(_ s: String, trimming: Bool = true) -> String {
        let flat = trimming ? s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") : s
        let composed = flat.precomposedStringWithCanonicalMapping
        return trimming ? composed.trimmingCharacters(in: .whitespaces) : composed
    }

    private static func matches(_ key: [Character], in chars: [Character], at i: Int) -> Bool {
        guard !key.isEmpty, i + key.count <= chars.count else { return false }
        for (k, c) in zip(key, chars[i..<(i + key.count)]) where k != c { return false }
        return true
    }
}
