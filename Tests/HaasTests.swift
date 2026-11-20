import XCTest

final class HaasLayoutTests: XCTestCase {
    /// 使う範囲が [0, L) を隙間なく覆い、窓が 1504 フレームに収まり、境目が 8 の倍数か
    private func assertTiles(_ L: Int, file: StaticString = #filePath, line: UInt = #line) {
        let chunks = HaasLayout.chunks(L)
        XCTAssertFalse(chunks.isEmpty, "L=\(L)", file: file, line: line)
        var keep = 0
        for (i, c) in chunks.enumerated() {
            XCTAssertEqual(c.keepFrom, keep, "L=\(L) i=\(i) に隙間か重なり", file: file, line: line)
            XCTAssertGreaterThanOrEqual(c.start, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(c.start, c.keepFrom, file: file, line: line)
            XCTAssertGreaterThan(c.keepTo, c.keepFrom, file: file, line: line)
            XCTAssertLessThanOrEqual(c.keepTo - c.start, HaasLayout.window, "L=\(L) i=\(i) が窓に収まらない", file: file, line: line)
            XCTAssertEqual((c.keepFrom - c.start) % HaasLayout.sub, 0, file: file, line: line)
            if c.keepTo != L { XCTAssertEqual((c.keepTo - c.start) % HaasLayout.sub, 0, file: file, line: line) }
            keep = c.keepTo
        }
        XCTAssertEqual(keep, L, "L=\(L) の最後まで覆っていない", file: file, line: line)
    }

    func testShortIsOneWindow() {
        XCTAssertEqual(HaasLayout.chunks(400), [HaasLayout.Chunk(start: 0, keepFrom: 0, keepTo: 400)])
    }

    func testExactlyOneWindow() {
        // 15.04 秒ちょうど（1504 フレーム）は窓 1 つ
        XCTAssertEqual(HaasLayout.chunks(1504), [HaasLayout.Chunk(start: 0, keepFrom: 0, keepTo: 1504)])
    }

    func testJustOverOneWindow() {
        let chunks = HaasLayout.chunks(1505)
        XCTAssertEqual(chunks.count, 2)
        assertTiles(1505)
    }

    func testLongAudioTiles() {
        // 25.8 秒（2581 フレーム）・1 分・3 分と、窓の境目の前後
        for L in [2581, 6000, 18000, 1504 + 8, 1504 * 2, 1504 * 2 + 1, 2 * (1504 - 208) - 1, 2 * (1504 - 208)] {
            assertTiles(L)
        }
    }

    func testInnerEdgesDropContext() {
        // 2 つ目以降の窓は、使う範囲の手前に context（208 フレーム）以上の前置きを持つ
        let chunks = HaasLayout.chunks(6000)
        for c in chunks.dropFirst() {
            XCTAssertGreaterThanOrEqual(c.keepFrom - c.start, HaasLayout.context)
        }
    }

    func testTimeoutGrowsWithAudio() {
        XCTAssertEqual(HaasLayout.timeout(audioSeconds: 0), 5)
        XCTAssertEqual(HaasLayout.timeout(audioSeconds: 60), 20)
    }
}

final class HaasTokenizerTests: XCTestCase {
    /// id 0 は未知語、1〜256 はバイト（<0x00>〜<0xFF>）、そのあとに語
    private func tokenizer(_ words: [String]) -> HaasTokenizer {
        let bytes = (0..<256).map { String(format: "<0x%02X>", $0) }
        return HaasTokenizer(pieces: ["<unk>"] + bytes + words)
    }

    func testBytesJoinIntoUTF8() {
        let t = tokenizer([])
        // 「あ」= E3 81 82。バイトに分かれた日本語がつながる
        XCTAssertEqual(t.decode([1 + 0xE3, 1 + 0x81, 1 + 0x82]), "あ")
    }

    func testSpaceMarker() {
        let t = tokenizer(["\u{2581}Slack", "\u{2581}を", "見る"])
        // 先頭の空白は落とし、途中の ▁ は空白になる
        XCTAssertEqual(t.decode([257, 258, 259]), "Slack を見る")
    }

    func testUnknownIsDropped() {
        let t = tokenizer(["今日"])
        // 未知語（id 0）は貼り付ける文に混ぜない。範囲外の id も捨てる
        XCTAssertEqual(t.decode([0, 257, 9999]), "今日")
    }

    func testVocabJSON() throws {
        let t = try HaasTokenizer(vocabJSON: Data(#"["<unk>", "▁こんにちは"]"#.utf8))
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t.decode([1]), "こんにちは")
    }
}

final class HaasManifestTests: XCTestCase {
    private func json(version: String = "88d567e938441c4cb066a5da6ffce45e09a25206", folder: String = "haas-ja-v1.0-int8-88d567e",
                      drop: String? = nil, extra: [String] = []) -> Data {
        var paths = HaasManifest.resources + HaasManifest.packages.map { "\($0).mlpackage/Manifest.json" } + extra
        paths.removeAll { $0 == drop }
        let files = paths.map { #"{"path": "\#($0)", "size": 1, "sha256": "ab"}"# }.joined(separator: ",")
        return Data(#"{"version": "\#(version)", "folder": "\#(folder)", "source": "x", "files": [\#(files)]}"#.utf8)
    }

    func testParse() throws {
        let m = try HaasManifest.parse(json())
        XCTAssertEqual(m.version, "88d567e938441c4cb066a5da6ffce45e09a25206")
        XCTAssertEqual(m.folder, "haas-ja-v1.0-int8-88d567e")
        XCTAssertEqual(m.files.count, HaasManifest.resources.count + HaasManifest.packages.count)
    }

    func testVersionMustBeAFolderName() {
        // 手元のフォルダ名に使うので、区切り文字や .. は受け付けない
        XCTAssertThrowsError(try HaasManifest.parse(json(version: "../x")))
        XCTAssertThrowsError(try HaasManifest.parse(json(folder: "a/b")))
        XCTAssertThrowsError(try HaasManifest.parse(json(version: "")))
        XCTAssertThrowsError(try HaasManifest.parse(json(folder: ".hidden")))
    }

    func testRequiredFiles() {
        XCTAssertThrowsError(try HaasManifest.parse(json(drop: "vocab.json")))
        XCTAssertThrowsError(try HaasManifest.parse(json(drop: "encoder.mlpackage/Manifest.json")))
    }

    func testPathsStayInsideTheFolder() {
        XCTAssertThrowsError(try HaasManifest.parse(json(extra: ["../escape"])))
        XCTAssertThrowsError(try HaasManifest.parse(json(extra: ["/abs"])))
        XCTAssertNoThrow(try HaasManifest.parse(json(extra: ["LICENSE", "encoder.mlpackage/Data/weights/weight.bin"])))
    }
}

final class HaasConstantsTests: XCTestCase {
    /// okayuji 版（88d567e）の frontend.json から、照合する項目だけを抜いたもの
    private let frontend = """
    {"audio": {"sample_rate": 16000, "channels": 1},
     "frontend": {"preemph": 0.97, "n_fft": 512, "win_length": 400, "hop_length": 160, "n_mels": 128,
                  "stft": {"center": true, "bins": 257},
                  "log": {"zero_guard_value": 5.960464477539063e-08}, "normalize": {"eps": 1e-05}},
     "encoder": {"window_frames": 1504, "output_frames": 188, "subsampling": 8},
     "long_audio": {"window_frames": 1504, "dropped_frames_each_inner_edge": 208, "boundary_multiple": 8},
     "decoding": {"blank_id": 3072, "durations": [0, 1, 2, 3, 4], "max_symbols": 10},
     "decoder_state": {"first_token": 3072},
     "vocab": {"size": 3072}}
    """

    func testMatches() {
        XCTAssertEqual(HaasConstants.mismatches(frontendJSON: Data(frontend.utf8)), [])
    }

    func testDetectsChangedConstant() {
        let changed = frontend.replacingOccurrences(of: #""hop_length": 160"#, with: #""hop_length": 128"#)
            .replacingOccurrences(of: #""durations": [0, 1, 2, 3, 4]"#, with: #""durations": [0, 1, 2, 4, 8]"#)
        let found = HaasConstants.mismatches(frontendJSON: Data(changed.utf8))
        XCTAssertEqual(found.count, 2, "\(found)")
        XCTAssertEqual(found.first, "frontend.hop_length=128")
        XCTAssertTrue(found.last?.hasPrefix("decoding.durations=") == true, "\(found)")
    }

    func testDetectsMissingAndUnreadable() {
        let missing = frontend.replacingOccurrences(of: #""blank_id": 3072, "#, with: "")
        XCTAssertEqual(HaasConstants.mismatches(frontendJSON: Data(missing.utf8)), ["decoding.blank_id=なし"])
        XCTAssertEqual(HaasConstants.mismatches(frontendJSON: Data("not json".utf8)), ["frontend.json を読めない"])
    }

    func testBooleanIsNotANumber() {
        // JSON の true を 1 と取り違えない
        let changed = frontend.replacingOccurrences(of: #""channels": 1"#, with: #""channels": true"#)
        let found = HaasConstants.mismatches(frontendJSON: Data(changed.utf8))
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertTrue(found.first?.hasPrefix("audio.channels=") == true, "\(found)")
    }
}
