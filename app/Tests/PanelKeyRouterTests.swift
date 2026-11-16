import XCTest
import AppKit
@testable import BabelTower

/// 面板按键路由：
/// 组字中一律放行输入法；⌘C 按焦点与选区分流。
final class PanelKeyRouterTests: XCTestCase {

    private let command: NSEvent.ModifierFlags = .command
    private let shift: NSEvent.ModifierFlags = .shift

    private func action(_ keyCode: UInt16,
                        _ modifiers: NSEvent.ModifierFlags = [],
                        marked: Bool = false,
                        focus: PanelKeyRouter.FocusArea = .input,
                        resultSelection: Bool = false,
                        inputSelection: Bool = false,
                        hasInputText: Bool = true,
                        pinned: Bool = false) -> PanelKeyAction {
        PanelKeyRouter.action(
            keyCode: keyCode,
            modifiers: modifiers,
            hasMarkedText: marked,
            focus: focus,
            hasResultSelection: resultSelection,
            hasInputSelection: inputSelection,
            hasInputText: hasInputText,
            isPinned: pinned
        )
    }

    // MARK: 输入法组字（组字时 ↩ 和 Esc 交给输入法）

    func testMarkedTextAlwaysPassesThrough() {
        XCTAssertEqual(action(36, marked: true), .passthrough, "组字中 ↩ 放行")
        XCTAssertEqual(action(53, marked: true), .passthrough, "组字中 Esc 放行")
        XCTAssertEqual(action(8, command, marked: true), .passthrough, "组字中其他键也放行")
    }

    // MARK: ↩ 与 ⇧↩

    func testReturnTriggersTranslateOrCopyTake() {
        XCTAssertEqual(action(36), .translateOrCopyTake)
        XCTAssertEqual(action(36, shift), .passthrough, "⇧↩ 换行放行")
        XCTAssertEqual(action(36, command), .passthrough, "⌘↩ 非定义快捷键")
    }

    // MARK: Esc 收起

    func testEscapeCollapses() {
        XCTAssertEqual(action(53), .collapse)
    }

    // MARK: 固定状态（固定时 Esc 不收起）

    func testEscapePinnedPassthrough() {
        XCTAssertEqual(action(53, pinned: true), .passthrough, "固定时 Esc 放行（不收起）")
        XCTAssertEqual(action(53, pinned: false), .collapse, "非固定时 Esc 收起（现状不变）")
    }

    /// 固定只影响 Esc；↩ 仍走翻译/复制路径（收不收起由视图模型按固定状态决定），
    /// 组字规则不变（组字中一切按键交输入法，固定状态不改变）。
    func testPinningDoesNotChangeOtherKeys() {
        XCTAssertEqual(action(36, pinned: true), .translateOrCopyTake)
        XCTAssertEqual(action(53, marked: true, pinned: true), .passthrough)
        XCTAssertEqual(action(9, command, pinned: true), .pasteFromClipboard)
        XCTAssertEqual(action(8, command, pinned: true), .copyResultFull)
    }

    // MARK: ⌘C 分流

    func testCommandCWithoutSelectionCopiesFull() {
        XCTAssertEqual(action(8, command, focus: .result, resultSelection: false), .copyResultFull)
        XCTAssertEqual(action(8, command, focus: .input, inputSelection: false), .copyResultFull,
                       "焦点在输入框但没选中输入文字 → 复制全文")
    }

    func testCommandCWithResultSelectionCopiesSelection() {
        XCTAssertEqual(action(8, command, focus: .result, resultSelection: true), .copySelectedResult)
    }

    func testCommandCWithInputSelectionPassesThrough() {
        XCTAssertEqual(action(8, command, focus: .input, inputSelection: true), .passthrough,
                       "焦点在输入框且选中输入文字 → 系统默认复制输入文字")
    }

    // MARK: ⌘R / ⌘N / ⌘1-4 / ⌘0

    func testCommandVPastes() {
        XCTAssertEqual(action(9, command), .pasteFromClipboard)
    }

    func testCommandShortcuts() {
        XCTAssertEqual(action(15, command), .retranslate)
        XCTAssertEqual(action(45, command), .clearRound)
        XCTAssertEqual(action(18, command), .setTargetMode(.manual(.zhHans)))
        XCTAssertEqual(action(19, command), .setTargetMode(.manual(.zhHant)))
        XCTAssertEqual(action(20, command), .setTargetMode(.manual(.ja)))
        XCTAssertEqual(action(21, command), .setTargetMode(.manual(.en)))
        XCTAssertEqual(action(29, command), .setTargetMode(.automatic))
        // 数字键无 ⌘ 是普通输入
        XCTAssertEqual(action(18), .passthrough)
    }

    /// ⌫（输入框为空时删除最后一张图，有文字时是普通退格）。
    func testBackspaceRoutesByInputText() {
        XCTAssertEqual(action(51, [], hasInputText: false), .deleteLastImage)
        XCTAssertEqual(action(51, [], hasInputText: true), .passthrough)
    }

    func testUnmappedKeysPassThrough() {
        XCTAssertEqual(action(0), .passthrough)   // A
        XCTAssertEqual(action(49), .passthrough)  // 空格
        XCTAssertEqual(action(36, .option), .passthrough)
    }
}

/// 窗口位置记忆的有效性判定（用户拖动后记住位置）。
final class PanelPositionMemoryTests: XCTestCase {

    private let mainScreen = PanelGeometry.Screen(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 25, width: 1440, height: 850)
    )
    private let sideScreen = PanelGeometry.Screen(
        frame: NSRect(x: 1440, y: -100, width: 1920, height: 1180),
        visibleFrame: NSRect(x: 1440, y: -75, width: 1920, height: 1130)
    )

    func testFrameOnExistingScreenIsValid() {
        let frame = NSRect(x: 100, y: 100, width: 560, height: 240)
        XCTAssertTrue(PanelPositionMemory.frameIsValid(frame, screens: [mainScreen, sideScreen]))
        let sideFrame = NSRect(x: 1600, y: 0, width: 560, height: 240)
        XCTAssertTrue(PanelPositionMemory.frameIsValid(sideFrame, screens: [mainScreen, sideScreen]))
    }

    /// 记忆位置所在的显示器被拔掉 → 无效，回落默认定位。
    func testFrameOnMissingScreenIsInvalid() {
        let frame = NSRect(x: 5000, y: 5000, width: 560, height: 240)
        XCTAssertFalse(PanelPositionMemory.frameIsValid(frame, screens: [mainScreen, sideScreen]))
    }

    /// 与可见区完全无交集（藏在菜单栏上方等）→ 无效。
    func testFrameWithoutIntersectionIsInvalid() {
        let frame = NSRect(x: 0, y: 10_000, width: 560, height: 240)
        XCTAssertFalse(PanelPositionMemory.frameIsValid(frame, screens: [mainScreen, sideScreen]))
    }

    func testNilFrameIsInvalid() {
        XCTAssertFalse(PanelPositionMemory.frameIsValid(nil, screens: [mainScreen]))
    }
}
