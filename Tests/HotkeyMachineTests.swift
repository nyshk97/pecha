import XCTest

final class HotkeyMachineTests: XCTestCase {
    private let release = HotkeyConfig(recordCommand: FlagBits.leftCommand, dictionaryKeyCode: KeyCodes.ansi2)
    private let leftCmd = FlagBits.command | FlagBits.leftCommand
    private let rightCmd = FlagBits.command | FlagBits.rightCommand
    private let rightOpt = FlagBits.option | FlagBits.rightOption
    private let leftOpt = FlagBits.option | FlagBits.leftOption

    private func spaceDown(_ flags: UInt64, repeat r: Bool = false) -> KeyEvent { .keyDown(keyCode: KeyCodes.space, isRepeat: r, flags: flags) }
    private func spaceUp(_ flags: UInt64) -> KeyEvent { .keyUp(keyCode: KeyCodes.space, flags: flags) }

    func testPressAndReleaseSpaceRecords() {
        var m = HotkeyMachine(config: release)
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: KeyCodes.leftCommand, flags: leftCmd), at: 0), .pass)
        XCTAssertEqual(m.handle(spaceDown(leftCmd), at: 1), HotkeyDecision(swallow: true, action: .startRecording))
        XCTAssertTrue(m.isRecording)
        XCTAssertEqual(m.handle(spaceUp(leftCmd), at: 3),
                       HotkeyDecision(swallow: true, action: .finishRecording(reason: .spaceUp, duration: 2, discard: false)))
        XCTAssertFalse(m.isRecording)
        // ⌘ の解放は前面アプリに届け、録音はもう止まっているので何もしない
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: KeyCodes.leftCommand, flags: 0), at: 3.1), .pass)
    }

    func testShortPressIsDiscarded() {
        var m = HotkeyMachine(config: release)
        _ = m.handle(spaceDown(leftCmd), at: 10)
        XCTAssertEqual(m.handle(spaceUp(leftCmd), at: 10.29).action,
                       .finishRecording(reason: .spaceUp, duration: 10.29 - 10, discard: true))
        _ = m.handle(spaceDown(leftCmd), at: 20)
        guard case let .finishRecording(_, _, discard)? = m.handle(spaceUp(leftCmd), at: 20.3).action else { return XCTFail() }
        XCTAssertFalse(discard)
    }

    func testReleasingCommandFirstStopsAndKeepsSwallowingSpace() {
        var m = HotkeyMachine(config: release)
        _ = m.handle(spaceDown(leftCmd), at: 0)
        // ⌘ を先に離す → 録音は止まるが ⌘ の解放自体は前面アプリに届ける
        XCTAssertEqual(m.handle(.flagsChanged(keyCode: KeyCodes.leftCommand, flags: 0), at: 1),
                       HotkeyDecision(swallow: false, action: .finishRecording(reason: .commandUp, duration: 1, discard: false)))
        // Space はまだ押されている。リピートが前面アプリに漏れない
        XCTAssertEqual(m.handle(spaceDown(0, repeat: true), at: 1.1), HotkeyDecision(swallow: true, action: nil))
        XCTAssertEqual(m.handle(spaceDown(0, repeat: true), at: 1.2), HotkeyDecision(swallow: true, action: nil))
        XCTAssertEqual(m.handle(spaceUp(0), at: 1.5), HotkeyDecision(swallow: true, action: nil))
        // 以後の Space は普通に届く
        XCTAssertEqual(m.handle(spaceDown(0), at: 2), .pass)
        XCTAssertEqual(m.handle(spaceUp(0), at: 2.1), .pass)
    }

    func testRepeatWhileRecordingIsSwallowedWithoutRestart() {
        var m = HotkeyMachine(config: release)
        _ = m.handle(spaceDown(leftCmd), at: 0)
        XCTAssertEqual(m.handle(spaceDown(leftCmd, repeat: true), at: 0.5), HotkeyDecision(swallow: true, action: nil))
        XCTAssertTrue(m.isRecording)
    }

    func testRightCommandDoesNotRecordInReleaseConfig() {
        var m = HotkeyMachine(config: release)
        XCTAssertEqual(m.handle(spaceDown(rightCmd), at: 0), .pass)
        XCTAssertFalse(m.isRecording)
        // dev は右 ⌘
        var dev = HotkeyMachine(config: HotkeyConfig(recordCommand: FlagBits.rightCommand, dictionaryKeyCode: KeyCodes.ansi3))
        XCTAssertEqual(dev.handle(spaceDown(rightCmd), at: 0).action, .startRecording)
        XCTAssertEqual(dev.handle(.keyDown(keyCode: KeyCodes.space, isRepeat: false, flags: leftCmd), at: 5), HotkeyDecision(swallow: true, action: nil))
    }

    func testOtherModifiersDoNotRecord() {
        var m = HotkeyMachine(config: release)
        XCTAssertEqual(m.handle(spaceDown(leftCmd | FlagBits.shift), at: 0), .pass)
        XCTAssertEqual(m.handle(spaceDown(leftCmd | FlagBits.control), at: 0), .pass)
        XCTAssertEqual(m.handle(spaceDown(leftCmd | leftOpt), at: 0), .pass)
        XCTAssertEqual(m.handle(spaceDown(0), at: 0), .pass)
        XCTAssertFalse(m.isRecording)
    }

    func testRepeatWithoutStartDoesNotRecord() {
        // ⌘ を押す前から Space を押し続けていたリピート
        var m = HotkeyMachine(config: release)
        XCTAssertEqual(m.handle(spaceDown(leftCmd, repeat: true), at: 0), .pass)
    }

    func testLostKeyUpIsRecoveredByNextFreshPress() {
        var m = HotkeyMachine(config: release)
        _ = m.handle(spaceDown(leftCmd), at: 0)
        _ = m.handle(.flagsChanged(keyCode: KeyCodes.leftCommand, flags: 0), at: 1)
        // Space の keyUp を取りこぼしたまま、次の Space が来た（リピートでない）→ 普通に届ける
        XCTAssertEqual(m.handle(spaceDown(0), at: 5), .pass)
    }

    func testReconcileStopsWhenKeysAreActuallyUp() {
        var m = HotkeyMachine(config: release)
        _ = m.handle(spaceDown(leftCmd), at: 0)
        XCTAssertNil(m.reconcile(spaceDown: true, commandDown: true, dictionaryKeyDown: false, at: 1))
        XCTAssertEqual(m.reconcile(spaceDown: false, commandDown: true, dictionaryKeyDown: false, at: 2),
                       .finishRecording(reason: .lost, duration: 2, discard: false))
        XCTAssertFalse(m.isRecording)
        XCTAssertEqual(m.handle(spaceDown(0), at: 3), .pass)
    }

    func testDictionaryHotkey() {
        var m = HotkeyMachine(config: release)
        let two = KeyCodes.ansi2
        XCTAssertEqual(m.handle(.keyDown(keyCode: two, isRepeat: false, flags: rightOpt), at: 0), HotkeyDecision(swallow: true, action: .dictionary))
        XCTAssertEqual(m.handle(.keyDown(keyCode: two, isRepeat: true, flags: rightOpt), at: 0.5), HotkeyDecision(swallow: true, action: nil))
        XCTAssertEqual(m.handle(.keyUp(keyCode: two, flags: rightOpt), at: 0.6), HotkeyDecision(swallow: true, action: nil))
        // 左 ⌥ + 2（™ 等の入力）は届ける
        XCTAssertEqual(m.handle(.keyDown(keyCode: two, isRepeat: false, flags: leftOpt), at: 1), .pass)
        XCTAssertEqual(m.handle(.keyUp(keyCode: two, flags: leftOpt), at: 1.1), .pass)
        // 右 ⌥ + ⌘ + 2 は届ける
        XCTAssertEqual(m.handle(.keyDown(keyCode: two, isRepeat: false, flags: rightOpt | leftCmd), at: 2), .pass)
        // 素の 2 は届ける
        XCTAssertEqual(m.handle(.keyDown(keyCode: two, isRepeat: false, flags: 0), at: 3), .pass)
    }
}
