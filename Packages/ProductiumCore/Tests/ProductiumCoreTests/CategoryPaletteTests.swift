import XCTest
@testable import ProductiumCore

/// v1.1 J1: categories drawn next to each other differ enough in lightness to be told apart in grayscale.
final class CategoryPaletteTests: XCTestCase {
    func testNeighbouringCategoriesDifferInLightnessInLightAndDarkMode() {
        for isDark in [false, true] {
            for (i, a) in CategoryPalette.shown.enumerated() {
                for b in CategoryPalette.shown[(i + 1)...] {
                    let c = CategoryPalette.contrast(CategoryPalette.name(a), CategoryPalette.name(b), dark: isDark)
                    XCTAssertNotNil(c)
                    XCTAssertGreaterThanOrEqual(c ?? 0, CategoryPalette.minContrast,
                        "\(a) (\(CategoryPalette.name(a))) and \(b) (\(CategoryPalette.name(b))) look the same in grayscale (\(isDark ? "dark" : "light"))")
                }
            }
        }
    }

    func testTodaysBlueIndigoPurpleWouldHaveFailed() {
        // The old study / sleep / scrolling colours: blue and purple are one gray.
        XCTAssertLessThan(CategoryPalette.contrast("blue", "purple", dark: false)!, CategoryPalette.minContrast)
    }

    func testEveryCategoryHasItsOwnSymbol() {
        let all: [TimeCategory] = [.sleep, .school, .activities, .study, .commute, .routine, .screen, .free]
        XCTAssertEqual(Set(all.map(CategoryPalette.symbol)).count, all.count)
    }
}
