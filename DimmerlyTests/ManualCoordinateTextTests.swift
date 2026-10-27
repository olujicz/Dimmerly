//
//  ManualCoordinateTextTests.swift
//  DimmerlyTests
//
//  Unit tests for locale-aware parsing and formatting of manually entered coordinates.
//

@testable import Dimmerly
import XCTest

final class ManualCoordinateTextTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    func testParsesDotDecimalInEnglish() {
        XCTAssertEqual(ManualCoordinateText.parse("48.8566", locale: english), 48.8566)
    }

    func testParsesCommaDecimalInGerman() {
        XCTAssertEqual(ManualCoordinateText.parse("48,8566", locale: german), 48.8566)
    }

    func testAcceptsDotDecimalInCommaLocaleForPastedCoordinates() {
        XCTAssertEqual(ManualCoordinateText.parse("48.8566", locale: german), 48.8566)
    }

    func testRejectsCommaDecimalInDotLocale() {
        XCTAssertNil(ManualCoordinateText.parse("48,8566", locale: english))
    }

    func testParsesNegativeValuesAndTrimsWhitespace() {
        XCTAssertEqual(ManualCoordinateText.parse("  -74,006 ", locale: german), -74.006)
        XCTAssertEqual(ManualCoordinateText.parse("\u{2212}74.006", locale: english), -74.006)
    }

    func testRejectsNonNumericText() {
        XCTAssertNil(ManualCoordinateText.parse("", locale: english))
        XCTAssertNil(ManualCoordinateText.parse("north", locale: english))
    }

    func testFormatsWithLocaleDecimalSeparator() {
        XCTAssertEqual(ManualCoordinateText.format(48.85661, locale: german), "48,8566")
        XCTAssertEqual(ManualCoordinateText.format(48.85661, locale: english), "48.8566")
    }

    func testFormatDoesNotGroupOrPadDigits() {
        XCTAssertEqual(ManualCoordinateText.format(-122.5, locale: english), "-122.5")
        XCTAssertEqual(ManualCoordinateText.format(1000, locale: german), "1000")
    }

    func testFormattedValueRoundTrips() {
        for locale in [english, german, Locale(identifier: "fr_FR"), Locale(identifier: "sr_RS")] {
            let text = ManualCoordinateText.format(-33.8688, locale: locale)
            XCTAssertEqual(ManualCoordinateText.parse(text, locale: locale), -33.8688, "\(locale.identifier)")
        }
    }
}
