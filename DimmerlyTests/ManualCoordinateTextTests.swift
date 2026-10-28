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
        XCTAssertNil(ManualCoordinateText.parse("48.85north", locale: english))
        XCTAssertNil(ManualCoordinateText.parse("٤٨٫٨٥north", locale: Locale(identifier: "ar_SA")))
    }

    func testParsesLocalizedDigitsAndDirectionalMarks() {
        XCTAssertEqual(ManualCoordinateText.parse("\u{061C}-٣٣٫٨٦٨٨", locale: Locale(identifier: "ar_SA")), -33.8688)
        XCTAssertEqual(ManualCoordinateText.parse("\u{200E}−۳۳٫۸۶۸۸", locale: Locale(identifier: "fa_IR")), -33.8688)
    }

    func testAcceptsPastedDotDecimalInLocalizedDigitLocales() {
        for identifier in ["ar_SA", "fa_IR"] {
            XCTAssertEqual(ManualCoordinateText.parse("-33.8688", locale: Locale(identifier: identifier)), -33.8688)
        }
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
        for identifier in ["en_US", "de_DE", "fr_FR", "sr_RS", "ar_SA", "ar_EG", "fa_IR"] {
            let locale = Locale(identifier: identifier)
            for value in [-33.8688, 48.8566, 0] {
                let text = ManualCoordinateText.format(value, locale: locale)
                XCTAssertEqual(ManualCoordinateText.parse(text, locale: locale), value, "\(identifier): \(text)")
            }
        }
    }
}
