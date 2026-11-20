// Sanami/haas-ja-coreml（Apache-2.0。ThirdParty/haas-ja-coreml/）の swift/Sources/HaasCore/Tokenizer.swift を写して変更した。
// 変更: 語の一覧を配列で受け取る（ファイルは呼ぶ側で読む）。未知語（id 0）は貼り付ける文に混ざらないよう捨てる。
import Foundation

/// SentencePiece decoding for the Haas vocabulary: "▁" -> space, "<0xXX>" byte-fallback pieces -> raw bytes,
/// leading space dropped (as sentencepiece's decode).
struct HaasTokenizer {
    static let unknownID = 0
    let pieces: [[UInt8]]

    /// `vocab.json` の中身（id 順の語）
    init(pieces list: [String]) {
        pieces = list.map { p in
            if p.count == 6, p.hasPrefix("<0x"), p.hasSuffix(">"), let b = UInt8(p.dropFirst(3).prefix(2), radix: 16) {
                return [b]
            }
            return Array(p.replacingOccurrences(of: "\u{2581}", with: " ").utf8)
        }
    }

    init(vocabJSON data: Data) throws {
        self.init(pieces: try JSONDecoder().decode([String].self, from: data))
    }

    var count: Int { pieces.count }

    func decode(_ ids: [Int]) -> String {
        var bytes = [UInt8]()
        for i in ids where i > Self.unknownID && i < pieces.count { bytes += pieces[i] }
        var s = String(decoding: bytes, as: UTF8.self)
        if s.hasPrefix(" ") { s.removeFirst() }
        return s
    }
}
