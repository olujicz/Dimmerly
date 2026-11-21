@testable import Dimmerly
import XCTest

final class KelvinFormattingTests: XCTestCase {
    /// Warmth 0.5 is 4,200 K and 0.0 is 6,500 K, so both have a grouping separator to localize.
    private let neutral = 0.0

    func testVisibleReadoutGroupsThousandsForEnglish() {
        let text = GammaMath.formattedKelvin(forWarmth: neutral, locale: Locale(identifier: "en_US"))

        XCTAssertTrue(text.contains("6,500"), text)
        XCTAssertTrue(text.contains("K"), text)
    }

    func testVisibleReadoutFollowsTheLocalesSeparator() {
        let german = GammaMath.formattedKelvin(forWarmth: neutral, locale: Locale(identifier: "de_DE"))
        let french = GammaMath.formattedKelvin(forWarmth: neutral, locale: Locale(identifier: "fr_FR"))

        XCTAssertTrue(german.contains("6.500"), german)
        XCTAssertFalse(french.contains("6,500") || french.contains("6.500"), french)
        XCTAssertTrue(french.hasPrefix("6"), french)
    }

    func testReadoutIsNotConvertedToAnotherTemperatureScale() {
        // A US locale prefers Fahrenheit for temperatures; a colour temperature must stay in kelvin.
        let text = GammaMath.formattedKelvin(forWarmth: 1.0, locale: Locale(identifier: "en_US"))

        XCTAssertTrue(text.contains("1,900"), text)
        XCTAssertFalse(text.contains("°"), text)
    }

    func testReadoutRoundsToWholeKelvins() {
        let text = GammaMath.formattedKelvin(forWarmth: 0.123_456, locale: Locale(identifier: "en_US"))

        XCTAssertFalse(text.contains("."), text)
    }

    func testSpokenValueSpellsTheUnitOut() {
        let spoken = GammaMath.spokenWarmth(neutral, isAutomatic: false, locale: Locale(identifier: "en_US"))

        XCTAssertTrue(spoken.contains("6,500"), spoken)
        XCTAssertTrue(spoken.lowercased().contains("kelvin"), spoken)
    }

    func testSpokenValueKeepsTheAutomaticQualifier() {
        let manual = GammaMath.spokenWarmth(neutral, isAutomatic: false, locale: Locale(identifier: "en_US"))
        let automatic = GammaMath.spokenWarmth(neutral, isAutomatic: true, locale: Locale(identifier: "en_US"))

        XCTAssertTrue(automatic.hasPrefix(manual), automatic)
        XCTAssertTrue(automatic.lowercased().contains("automatic"), automatic)
        XCTAssertFalse(manual.lowercased().contains("automatic"), manual)
    }
}
