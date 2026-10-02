import XCTest

/// 読みで当てる置換の検査表。誤爆と取りこぼしを数える。
/// 実際に使って出た誤認識（とそれを直す辞書）は `cases` に足していく
final class DictionaryReadingTests: XCTestCase {
    private let dict = ["衣臭": "issue", "生ため": "生天目", "PRC": "keyrc", "1周": "issue"]

    private enum Kind { case shouldFix, shouldKeep, knownMiss, knownFalsePositive }

    /// (認識の出力, 期待する結果, 種類)。knownMiss / knownFalsePositive は、今の仕組みでは直せないと分かっているもの
    private let cases: [(String, String, Kind)] = [
        ("この衣臭を作って。", "このissueを作って。", .shouldFix),
        ("このイシューを作って。", "このissueを作って。", .shouldFix),               // 「誤」の読み
        ("生ためさんに伝えてください。", "生天目さんに伝えてください。", .shouldFix),
        ("生田目さんに伝えて下さい", "生天目さんに伝えて下さい", .shouldFix),         // 「正」の読み
        ("PRCとキャピットを直します。", "keyrcとキャピットを直します。", .shouldFix),
        ("1周を見てください", "issueを見てください", .shouldFix),
        ("一周を見てください", "issueを見てください", .shouldFix),                   // 数字をそろえた読み
        ("生天目さんに伝えて", "生天目さんに伝えて", .shouldKeep),                   // 正しい表記はそのまま
        ("一周年記念のパーティー", "一周年記念のパーティー", .shouldKeep),             // 語の途中には当てない
        ("11周目に入った", "11周目に入った", .shouldKeep),                         // 英数字の境界
        ("医師がいる", "医師がいる", .shouldKeep),
        ("生野菜を食べる", "生野菜を食べる", .shouldKeep),
        ("今日はいい天気ですね。", "今日はいい天気ですね。", .shouldKeep),
        ("明日の会議は 10時からです。", "明日の会議は 10時からです。", .shouldKeep),
        // 読みが違う誤認識（ぐるく / ぷるく）。出た形を登録するしかない
        ("GRCとキャピットを直します。", "GRCとキャピットを直します。", .knownMiss),
        // 普通の語を「誤」に登録すると、本当にその語を言ったときも当たる（文脈ごと登録して避ける）
        ("グラウンドを1周しました", "グラウンドをissueしました", .knownFalsePositive),
        ("グラウンドを一周しました", "グラウンドをissueしました", .knownFalsePositive),
        // 「衣臭」と同じ読みの別の語
        ("異臭がする", "issueがする", .knownFalsePositive),
    ]

    func testTable() {
        var fixed = 0, kept = 0
        for (input, expected, kind) in cases {
            let got = DictionaryFile.replace(input, using: dict).text
            XCTAssertEqual(got, expected, "\(kind): \(input)")
            if got == expected, kind == .shouldFix { fixed += 1 }
            if got == expected, kind == .shouldKeep { kept += 1 }
        }
        let misses = cases.filter { $0.2 == .knownMiss }.count
        let falsePositives = cases.filter { $0.2 == .knownFalsePositive }.count
        print("dictionary-reading: fixed=\(fixed)/\(cases.filter { $0.2 == .shouldFix }.count) kept=\(kept) known_miss=\(misses) known_false_positive=\(falsePositives)")
    }

    func testReadingOfSameSoundMatches() {
        XCTAssertEqual(Yomi.reading("衣臭"), Yomi.reading("イシュー"))
        XCTAssertEqual(Yomi.reading("生田目"), Yomi.reading("生天目"))
        XCTAssertEqual(Yomi.reading("1周"), Yomi.reading("一周"))
    }

    func testShortReadingIsNotUsed() {
        // 「目」の読み（め）は短いので、読みでは当てない（「め」「眼」等を巻き込まない）
        XCTAssertEqual(DictionaryFile.replace("ひとつめの眼", using: ["目": "メ"]).text, "ひとつめの眼")
    }

    func testLatinOnlyRightIsNotUsedAsReading() {
        // 「正」の issue のローマ字読み（いっすえ）では当てない
        XCTAssertEqual(DictionaryFile.replace("いっすえ", using: ["衣臭": "issue"]).text, "いっすえ")
    }

    func testSpeedWithManyEntries() {
        var map: [String: String] = [:]
        for i in 0..<300 { map["誤語\(i)番"] = "正語\(i)" }
        map["衣臭"] = "issue"
        _ = DictionaryFile.replace("ウォームアップ", using: map)   // 読みの覚えを温める
        let text = "このイシューを作ってから、生田目さんに伝えて、明日の会議は 10時からにします。"
        let start = CFAbsoluteTimeGetCurrent()
        let result = DictionaryFile.replace(text, using: map)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("dictionary-reading: entries=\(map.count) ms=\(String(format: "%.1f", ms))")
        XCTAssertTrue(result.text.contains("issue"))
        XCTAssertLessThan(ms, 50)
    }
}
