import XCTest

final class DictionaryFileTests: XCTestCase {
    func testParse() {
        let text = """
        # コメント
        生ため => 生天目

          クロード   =>   Claude
        ヒントだけの行
        => 空の誤
        PRC => keyrc
        生ため => 生天目さん
        矢印 => a => b
        """
        let map = DictionaryFile.parse(text)
        XCTAssertEqual(map["クロード"], "Claude")
        XCTAssertEqual(map["PRC"], "keyrc")
        // 同じ「誤」は後の行を採用（last-wins）
        XCTAssertEqual(map["生ため"], "生天目さん")
        // 最初の => で分ける
        XCTAssertEqual(map["矢印"], "a => b")
        XCTAssertEqual(map.count, 4)
    }

    func testParseCRLF() {
        XCTAssertEqual(DictionaryFile.parse("a => b\r\nc => d\r\n"), ["a": "b", "c": "d"])
    }

    func testReplaceLeftmostLongest() {
        let map = ["生ため": "生天目", "生": "なま", "PRC": "keyrc"]
        let r = DictionaryFile.replace("生ためさんに PRC を", using: map)
        XCTAssertEqual(r.text, "生天目さんに keyrc を")
        XCTAssertEqual(r.hits, 2)
    }

    func testReplaceDoesNotChain() {
        let r = DictionaryFile.replace("A と B", using: ["A": "B", "B": "C"])
        XCTAssertEqual(r.text, "B と C")
        XCTAssertEqual(r.hits, 2)
    }

    func testReplaceNoMatchAndEmpty() {
        XCTAssertEqual(DictionaryFile.replace("そのまま", using: ["x": "y"]).text, "そのまま")
        XCTAssertEqual(DictionaryFile.replace("そのまま", using: [:]).hits, 0)
        XCTAssertEqual(DictionaryFile.replace("", using: ["x": "y"]).text, "")
    }

    func testReplaceWithEmptyRightRemoves() {
        XCTAssertEqual(DictionaryFile.replace("えーと今日は", using: ["えーと": ""]).text, "今日は")
    }

    func testReplaceKeepsEmojiAndNormalizesComposition() {
        // 分解形（か + 濁点）の入力でも合成形の「誤」に当たる
        let decomposed = "か\u{3099}いき"
        XCTAssertEqual(DictionaryFile.replace(decomposed, using: ["がいき": "外気"]).text, "外気")
        XCTAssertEqual(DictionaryFile.replace("👨‍👩‍👧 と 🇯🇵", using: ["と": "&"]).text, "👨‍👩‍👧 & 🇯🇵")
    }

    func testAppendLineAddsMissingNewline() {
        XCTAssertEqual(DictionaryFile.appendLine(wrong: "生ため", right: "生天目", existingEndsWithNewline: true), "生ため => 生天目\n")
        XCTAssertEqual(DictionaryFile.appendLine(wrong: "生ため", right: "生天目", existingEndsWithNewline: false), "\n生ため => 生天目\n")
        // 改行を含む選択は 1 行にする
        XCTAssertEqual(DictionaryFile.appendLine(wrong: "a\nb", right: " c ", existingEndsWithNewline: true), "a b => c\n")
    }

    func testAppendThenParseRoundTrip() {
        var file = "生ため => 生田目"   // 手で書いて最後に改行が無い
        file += DictionaryFile.appendLine(wrong: "生ため", right: "生天目", existingEndsWithNewline: file.hasSuffix("\n"))
        file += DictionaryFile.appendLine(wrong: "PRC", right: "keyrc", existingEndsWithNewline: file.hasSuffix("\n"))
        XCTAssertEqual(DictionaryFile.parse(file), ["生ため": "生天目", "PRC": "keyrc"])
    }

    func testValidate() {
        XCTAssertNil(DictionaryFile.validate(wrong: "生ため", right: "生天目"))
        XCTAssertNotNil(DictionaryFile.validate(wrong: "  ", right: "x"))
        XCTAssertNotNil(DictionaryFile.validate(wrong: "#tag", right: "x"))
        XCTAssertNotNil(DictionaryFile.validate(wrong: "a=>b", right: "x"))
        XCTAssertNotNil(DictionaryFile.validate(wrong: "x", right: "a => b"))
        XCTAssertNotNil(DictionaryFile.validate(wrong: "同じ", right: "同じ"))
        XCTAssertNil(DictionaryFile.validate(wrong: "えーと", right: ""))
    }

    func testLevel() {
        XCTAssertEqual(Level.normalized(rms: 0), 0)
        XCTAssertEqual(Level.normalized(rms: 1), 1)
        XCTAssertEqual(Level.normalized(rms: 0.001), 0)   // -60dB
        XCTAssertEqual(Level.normalized(rms: 0.01), 0.25, accuracy: 0.001)  // -40dB
    }
}
