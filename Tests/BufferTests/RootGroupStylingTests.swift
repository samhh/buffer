import XCTest
@testable import Buffer

final class RootGroupStylingTests: XCTestCase {
    func testRootGroupsAreDeterministicForSameInput() {
        let text = """
        Parent A
          child A1
          child A2

        Parent B
          child B1
        """
        let nsText = text as NSString

        let lines = RootGroupStyling.parseLines(in: nsText)
        let first = RootGroupStyling.rootGroups(from: lines, paletteCount: 5)
        for _ in 0..<20 {
            let nextLines = RootGroupStyling.parseLines(in: nsText)
            let next = RootGroupStyling.rootGroups(from: nextLines, paletteCount: 5)
            XCTAssertEqual(first.count, next.count)
            for (a, b) in zip(first, next) {
                XCTAssertEqual(a.lineIndices, b.lineIndices)
                XCTAssertEqual(a.colorIndex, b.colorIndex)
            }
        }
    }

    func testStableColorIndexIsPureForSameInputs() {
        let rootKey = "Project Alpha"
        let idx1 = RootGroupStyling.stableColorIndex(forRootKey: rootKey, paletteCount: 5)
        let idx2 = RootGroupStyling.stableColorIndex(forRootKey: rootKey, paletteCount: 5)
        XCTAssertEqual(idx1, idx2)
    }

    func testColorUnaffectedByPrecedingNonBlockContent() {
        let withPrefix = """
        intro
        notes
        bar
          baz
        """
        let withoutPrefix = """
        bar
          baz
        """

        let linesA = RootGroupStyling.parseLines(in: withPrefix as NSString)
        let linesB = RootGroupStyling.parseLines(in: withoutPrefix as NSString)
        let groupsA = RootGroupStyling.rootGroups(from: linesA, paletteCount: 5)
        let groupsB = RootGroupStyling.rootGroups(from: linesB, paletteCount: 5)

        XCTAssertEqual(groupsA.count, 1)
        XCTAssertEqual(groupsB.count, 1)
        XCTAssertEqual(groupsA[0].colorIndex, groupsB[0].colorIndex)
    }

    func testColorDependsOnRootNotChildren() {
        let textA = """
        Root
          child one
        """
        let textB = """
        Root
          totally different
          subtree
        """

        let groupsA = RootGroupStyling.rootGroups(from: RootGroupStyling.parseLines(in: textA as NSString), paletteCount: 5)
        let groupsB = RootGroupStyling.rootGroups(from: RootGroupStyling.parseLines(in: textB as NSString), paletteCount: 5)

        XCTAssertEqual(groupsA.count, 1)
        XCTAssertEqual(groupsB.count, 1)
        XCTAssertEqual(groupsA[0].colorIndex, groupsB[0].colorIndex)
    }
}
