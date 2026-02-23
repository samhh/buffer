import XCTest
@testable import Buffer

final class SmartListEditingTests: XCTestCase {
    func testEnterAfterClearingListItemCreatesPlainNewline() {
        var text = "- foo"
        var selection = NSRange(location: text.count, length: 0)

        (text, selection) = apply(.enter, to: text, selection: selection)
        XCTAssertEqual(text, "- foo\n- ")

        (text, selection) = apply(.enter, to: text, selection: selection)
        XCTAssertEqual(text, "- foo\n")

        (text, selection) = apply(.enter, to: text, selection: selection)
        XCTAssertEqual(text, "- foo\n\n")
    }

    func testIndentDoesNotMutateSyntheticNextLine() {
        let text = "- foo\nbar\n"
        let selection = NSRange(location: 6, length: 0) // Start of "bar"

        let (updated, _) = apply(.indent, to: text, selection: selection)
        XCTAssertEqual(updated, "- foo\n  - bar\n")
    }

    func testBackspaceInListPrefixDeletesToLineStart() {
        let text = "  - foo"
        let selection = NSRange(location: 3, length: 0) // After "  -"

        let (updated, newSelection) = apply(.backspace, to: text, selection: selection)
        XCTAssertEqual(updated, " foo")
        XCTAssertEqual(newSelection.location, 0)
        XCTAssertEqual(newSelection.length, 0)
    }

    func testTabOnEmptyLineMatchesDirectlyAboveListIndent() {
        let text = "  - parent\n"
        let selection = NSRange(location: text.count, length: 0)

        let (updated, newSelection) = apply(.indent, to: text, selection: selection)
        XCTAssertEqual(updated, "  - parent\n  - ")
        XCTAssertEqual(newSelection.location, "  - parent\n  - ".count)
    }

    func testTabOnEmptyLineWithoutDirectAboveListCreatesListItemInPlace() {
        let text = "heading\n"
        let selection = NSRange(location: text.count, length: 0)

        let (updated, newSelection) = apply(.indent, to: text, selection: selection)
        XCTAssertEqual(updated, "heading\n- ")
        XCTAssertEqual(newSelection.location, updated.count)
    }

    private func apply(_ action: SmartListAction, to text: String, selection: NSRange) -> (String, NSRange) {
        let edit = SmartListEditing.makeEdit(text: text, selection: selection, action: action)
        XCTAssertTrue(edit.handled, "Expected action to be handled: \(action)")
        let nsText = text as NSString
        let updated = nsText.replacingCharacters(in: edit.replacementRange, with: edit.replacement)
        return (updated, edit.selection)
    }
}
