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

    func testColorsCycleTopToBottomByGroupOrder() {
        let text = """
        A
            a1
        B
            b1
        C
            c1
        D
            d1
        """
        let groups = RootGroupStyling.rootGroups(from: RootGroupStyling.parseLines(in: text as NSString), paletteCount: 3)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map(\.colorIndex), [0, 1, 2, 0])
    }
}
