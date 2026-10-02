import Foundation

/// 文の読み（ひらがな）。macOS 標準の `CFStringTokenizer` で語に区切り、語ごとのローマ字の読みをひらがなにする。
///
/// 語ごとに読むので、つながったときの音の変化は入らない（「一周」は「いち＋しゅう」）。
/// それでも同じ音の別表記はそろう（「衣臭」「イシュー」はどちらも「いしゅう」、「生田目」「生天目」は「なまため」）。
/// 英字はローマ字読み（issue → いっすえ）になるので、英字だけの語の読みは照合に使わない
enum Yomi {
    struct Token: Equatable {
        /// 元の文の中の範囲（UTF-16）
        let range: NSRange
        let reading: String
    }

    /// 数字は漢数字にそろえてから読む（「1周」と「一周」を同じ読みにする）。文字数は変わらないので範囲は元の文に使える
    static func tokens(_ text: String) -> [Token] {
        let source = digitsToKanji(text) as NSString
        let tokenizer = CFStringTokenizerCreate(nil, source, CFRangeMake(0, source.length),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja_JP") as CFLocale)
        var out: [Token] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let range = NSRange(location: r.location, length: r.length)
            var reading = source.substring(with: range)
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let m = NSMutableString(string: latin)
                CFStringTransform(m, nil, kCFStringTransformLatinHiragana, false)
                reading = m as String
            }
            reading = reading.trimmingCharacters(in: .whitespaces)
            if !reading.isEmpty { out.append(Token(range: range, reading: reading)) }
        }
        return out
    }

    static func reading(_ text: String) -> String {
        lock.lock()
        if let cached = cache[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = tokens(text).map(\.reading).joined()
        lock.lock()
        cache[text] = value
        lock.unlock()
        return value
    }

    /// 辞書の語の読みは録音のたびに同じなので覚えておく
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    private static func digitsToKanji(_ s: String) -> String {
        let map: [Character: Character] = ["0": "〇", "1": "一", "2": "二", "3": "三", "4": "四",
                                           "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"]
        return String(s.map { map[$0] ?? $0 })
    }
}
