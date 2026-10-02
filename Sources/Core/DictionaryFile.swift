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

    /// 読みでの照合に使う読みの最短の長さ（ひらがなの文字数）。短い読みは普通の語に当たりやすい
    static let minimumReadingLength = 3

    /// 当て方は 3 つ:
    /// ① 文字列の完全一致（「誤」の端が英数字なら、そこに隣り合う文字も英数字のときは当てない。「11周」の「1周」等）
    /// ② 「誤」の読みでの一致（「衣臭」で登録すれば「イシュー」も、「1周」で登録すれば「一周」も拾う）
    /// ③ 「正」の読みでの一致（「生天目」の読みで「生田目」も拾う。「正」が英字だけならローマ字読みになるので使わない）
    /// ②③ は語の区切りにそろえ（「一周年」の途中には当てない）、読みが短い語には使わない。英数字の境界は①と同じに見る。
    /// 候補の中から、左から順に・同じ位置なら長いものを・同じなら①を、重ならないように 1 回だけ当てる。
    /// 置き換えた部分には二度と当てないので、`A => B` と `B => C` があっても A が C になる連鎖は起きない
    static func replace(_ text: String, using map: [String: String]) -> (text: String, hits: Int) {
        guard !map.isEmpty else { return (text, 0) }
        let source = normalize(text, trimming: false) as NSString
        var candidates: [Candidate] = []

        // ① 文字列の完全一致
        for (wrong, right) in map {
            var from = 0
            while from < source.length {
                let found = source.range(of: wrong, options: .literal, range: NSRange(location: from, length: source.length - from))
                if found.location == NSNotFound { break }
                if !touchesAlphanumeric(found, in: source) {
                    candidates.append(Candidate(range: found, replacement: right, priority: 0))
                }
                from = found.location + 1
            }
        }

        // ②③ 読みでの一致
        let tokens = Yomi.tokens(source as String)
        var keys: [(reading: String, replacement: String)] = []
        for (wrong, right) in map {
            keys.append((Yomi.reading(wrong), right))
            if !right.isEmpty, !isLatinOnly(right) { keys.append((Yomi.reading(right), right)) }
        }
        for key in keys where key.reading.count >= minimumReadingLength {
            for start in tokens.indices {
                var joined = ""
                for end in start..<tokens.count {
                    joined += tokens[end].reading
                    guard key.reading.hasPrefix(joined) else { break }
                    if joined == key.reading {
                        let range = NSRange(location: tokens[start].range.location,
                                            length: NSMaxRange(tokens[end].range) - tokens[start].range.location)
                        // すでに正しい表記なら当てない（「生天目」を「生天目」にしない）。英数字の境界は①と同じに見る
                        if source.substring(with: range) != key.replacement, !touchesAlphanumeric(range, in: source) {
                            candidates.append(Candidate(range: range, replacement: key.replacement, priority: 1))
                        }
                        break
                    }
                }
            }
        }

        candidates.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.priority < $1.priority
        }
        var out = ""
        var position = 0
        var hits = 0
        for c in candidates where c.range.location >= position {
            out += source.substring(with: NSRange(location: position, length: c.range.location - position))
            out += c.replacement
            position = NSMaxRange(c.range)
            hits += 1
        }
        out += source.substring(from: position)
        return (out, hits)
    }

    private struct Candidate {
        let range: NSRange
        let replacement: String
        /// 同じ範囲なら小さいほうを採る（0 = 文字列の完全一致、1 = 読み）
        let priority: Int
    }

    /// 範囲の端が英数字で、その外側の隣も英数字か
    private static func touchesAlphanumeric(_ range: NSRange, in source: NSString) -> Bool {
        func isAlnum(_ index: Int) -> Bool {
            guard index >= 0, index < source.length, let scalar = Unicode.Scalar(source.character(at: index)) else { return false }
            return scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        }
        let first = range.location
        let last = NSMaxRange(range) - 1
        return (isAlnum(first) && isAlnum(first - 1)) || (isAlnum(last) && isAlnum(last + 1))
    }

    private static func isLatinOnly(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy(\.isASCII)
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
}
