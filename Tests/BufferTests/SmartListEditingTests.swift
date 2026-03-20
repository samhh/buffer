import XCTest
@testable import Buffer

final class SmartListEditingTests: XCTestCase {
    func testEnterAfterClearingIndentedLineCreatesPlainNewline() {
        var text = "foo"
        var selection = NSRange(location: text.count, length: 0)

        (text, selection) = apply(.enter, to: text, selection: selection)
        XCTAssertEqual(text, "foo\n")

        (text, selection) = apply(.indent, to: text, selection: selection)
        XCTAssertEqual(text, "foo\n    ")

        (text, selection) = apply(.enter, to: text, selection: selection)
        XCTAssertEqual(text, "foo\n")

        (text, selection) = apply(.enter, to: text, selection: selection)
        XCTAssertEqual(text, "foo\n\n")
    }

    func testIndentDoesNotMutateSyntheticNextLine() {
        let text = "foo\nbar\n"
        let selection = NSRange(location: 4, length: 0) // Start of "bar"

        let (updated, _) = apply(.indent, to: text, selection: selection)
        XCTAssertEqual(updated, "foo\n    bar\n")
    }

    func testBackspaceInIndentDeletesToLineStart() {
        let text = "    foo"
        let selection = NSRange(location: 4, length: 0) // After indent

        let (updated, newSelection) = apply(.backspace, to: text, selection: selection)
        XCTAssertEqual(updated, "foo")
        XCTAssertEqual(newSelection.location, 0)
        XCTAssertEqual(newSelection.length, 0)
    }

    func testTabOnEmptyLineIndentsInPlace() {
        let text = "parent\n"
        let selection = NSRange(location: text.count, length: 0)

        let (updated, newSelection) = apply(.indent, to: text, selection: selection)
        XCTAssertEqual(updated, "parent\n    ")
        XCTAssertEqual(newSelection.location, updated.count)
    }

    func testMoveLineUpMovesCaretLine() {
        let text = "one\ntwo\nthree"
        let selection = NSRange(location: 4, length: 0) // Start of "two"

        let (updated, newSelection) = apply(.moveLineUp, to: text, selection: selection)
        XCTAssertEqual(updated, "two\none\nthree")
        XCTAssertEqual(newSelection.location, 0)
        XCTAssertEqual(newSelection.length, 0)
    }

    func testMoveLineDownMovesCaretLine() {
        let text = "one\ntwo\nthree"
        let selection = NSRange(location: 4, length: 0) // Start of "two"

        let (updated, newSelection) = apply(.moveLineDown, to: text, selection: selection)
        XCTAssertEqual(updated, "one\nthree\ntwo")
        XCTAssertEqual(newSelection.location, 10)
        XCTAssertEqual(newSelection.length, 0)
    }

    func testMoveLineDownMovesWholeIntersectingLinesForPartialSelection() {
        let text = "aa\nbb\ncc\ndd"
        let selection = NSRange(location: 1, length: 5) // Partial across "aa\nbb"

        let (updated, newSelection) = apply(.moveLineDown, to: text, selection: selection)
        XCTAssertEqual(updated, "cc\naa\nbb\ndd")
        XCTAssertEqual(newSelection.location, 4)
        XCTAssertEqual(newSelection.length, 5)
    }

    func testMoveLineUpPreservesSelectionLengthForMultilineSelection() {
        let text = "l1\nl2\nl3\nl4\n"
        let selection = NSRange(location: 3, length: 6) // "l2\nl3\n"

        let (updated, newSelection) = apply(.moveLineUp, to: text, selection: selection)
        XCTAssertEqual(updated, "l2\nl3\nl1\nl4\n")
        XCTAssertEqual(newSelection.location, 0)
        XCTAssertEqual(newSelection.length, 6)
    }

    func testMoveLineUpAtTopIsUnhandled() {
        let text = "a\nb"
        let selection = NSRange(location: 0, length: 0)

        let edit = makeEdit(.moveLineUp, to: text, selection: selection)
        XCTAssertFalse(edit.handled)
    }

    func testMoveLineDownAtBottomIsUnhandled() {
        let text = "a\nb"
        let selection = NSRange(location: 2, length: 0) // Start of "b"

        let edit = makeEdit(.moveLineDown, to: text, selection: selection)
        XCTAssertFalse(edit.handled)
    }

    func testMoveLineDownSelectionEndingAtNewlineDoesNotCaptureNextLine() {
        let text = "a\nb\nc\n"
        let selection = NSRange(location: 2, length: 2) // "b\n", ending at start of "c"

        let (updated, newSelection) = apply(.moveLineDown, to: text, selection: selection)
        XCTAssertEqual(updated, "a\nc\nb\n")
        XCTAssertEqual(newSelection.location, 4)
        XCTAssertEqual(newSelection.length, 2)
    }

    // MARK: - subitemRange

    func testSubitemRangeDeletesSingleLineWithNoChildren() {
        let text = "one\ntwo\nthree"
        let nsText = text as NSString
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: 0)
        // Should only cover "one\n"
        XCTAssertEqual(nsText.substring(with: range), "one\n")
    }

    func testSubitemRangeDeletesLineAndImmediateChildren() {
        let text = "parent\n    child1\n    child2\nsibling"
        let nsText = text as NSString
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: 0)
        XCTAssertEqual(nsText.substring(with: range), "parent\n    child1\n    child2\n")
    }

    func testSubitemRangeDeletesNestedChildren() {
        let text = "parent\n    child\n        grandchild\nsibling"
        let nsText = text as NSString
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: 0)
        XCTAssertEqual(nsText.substring(with: range), "parent\n    child\n        grandchild\n")
    }

    func testSubitemRangeFromChildDeletesOnlyDeeperItems() {
        let text = "parent\n    child\n        grandchild\n    child2\nsibling"
        let nsText = text as NSString
        // Caret on "    child" (location 7)
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: 7)
        XCTAssertEqual(nsText.substring(with: range), "    child\n        grandchild\n")
    }

    func testSubitemRangeDoesNotIncludeTrailingEmptyLines() {
        let text = "parent\n    child\n\nsibling"
        let nsText = text as NSString
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: 0)
        // The empty line should NOT be included since it's followed by a non-child
        XCTAssertEqual(nsText.substring(with: range), "parent\n    child\n")
    }

    func testSubitemRangeIncludesEmptyLinesBetweenChildren() {
        let text = "parent\n    child1\n\n    child2\nsibling"
        let nsText = text as NSString
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: 0)
        XCTAssertEqual(nsText.substring(with: range), "parent\n    child1\n\n    child2\n")
    }

    func testSubitemRangeAtLastLineWithNoNewline() {
        let text = "one\ntwo"
        let nsText = text as NSString
        let range = SmartListEditing.subitemRange(in: nsText, caretLocation: 4)
        XCTAssertEqual(nsText.substring(with: range), "two")
    }

    private func apply(_ action: SmartListAction, to text: String, selection: NSRange) -> (String, NSRange) {
        let edit = makeEdit(action, to: text, selection: selection)
        XCTAssertTrue(edit.handled, "Expected action to be handled: \(action)")
        let nsText = text as NSString
        let updated = nsText.replacingCharacters(in: edit.replacementRange, with: edit.replacement)
        return (updated, edit.selection)
    }

    private func makeEdit(_ action: SmartListAction, to text: String, selection: NSRange) -> SmartListEdit {
        SmartListEditing.makeEdit(text: text, selection: selection, action: action)
    }
}
