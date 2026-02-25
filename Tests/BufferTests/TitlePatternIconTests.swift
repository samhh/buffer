import XCTest
@testable import Buffer

final class TitlePatternIconTests: XCTestCase {
    func testSpecIsDeterministicForSameTitle() {
        let title = "Project Plan"
        let first = TitlePatternGenerator.spec(for: title)
        for _ in 0..<20 {
            XCTAssertEqual(first, TitlePatternGenerator.spec(for: title))
        }
    }

    func testNormalizationCollapsesWhitespaceAndCase() {
        XCTAssertEqual(normalizedTitleKey("  Foo   Bar "), "foo bar")
        XCTAssertEqual(
            TitlePatternGenerator.spec(for: "  Foo   Bar "),
            TitlePatternGenerator.spec(for: "foo bar")
        )
    }

    func testStabilitySamples() {
        XCTAssertEqual(
            TitlePatternGenerator.spec(for: "alpha"),
            TitlePatternSpec(
                paletteIndex: 3,
                patternKind: .diagonalDown,
                rotationQuarterTurns: 2,
                density: 1,
                accentMix: 0
            )
        )
        XCTAssertEqual(
            TitlePatternGenerator.spec(for: "Project Plan"),
            TitlePatternSpec(
                paletteIndex: 1,
                patternKind: .diagonalUp,
                rotationQuarterTurns: 3,
                density: 0,
                accentMix: 1
            )
        )
        XCTAssertEqual(
            TitlePatternGenerator.spec(for: ""),
            TitlePatternSpec(
                paletteIndex: 5,
                patternKind: .diagonalDown,
                rotationQuarterTurns: 2,
                density: 0,
                accentMix: 0
            )
        )
    }

    func testMappedValuesRemainWithinBounds() {
        let samples = [
            "",
            "a",
            "alpha",
            "Buy milk",
            "Quick note about Tuesday deployment",
            "   leading and trailing   ",
            "emoji test 😀 title"
        ]

        for sample in samples {
            let spec = TitlePatternGenerator.spec(for: sample)
            XCTAssertGreaterThanOrEqual(spec.paletteIndex, 0)
            XCTAssertLessThan(spec.paletteIndex, TitlePatternGenerator.paletteCount)
            XCTAssertGreaterThanOrEqual(spec.rotationQuarterTurns, 0)
            XCTAssertLessThan(spec.rotationQuarterTurns, 4)
            XCTAssertGreaterThanOrEqual(spec.density, 0)
            XCTAssertLessThan(spec.density, TitlePatternGenerator.densityLevels)
            XCTAssertGreaterThanOrEqual(spec.accentMix, 0)
            XCTAssertLessThan(spec.accentMix, TitlePatternGenerator.accentMixLevels)
        }
    }
}
