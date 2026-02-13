//
//  SolarCalculator.swift
//  Dimmerly
//
//  Pure-math NOAA solar position algorithm for calculating sunrise and sunset times.
//  No external dependencies, network calls, or third-party libraries.
//
//  Algorithm source: NOAA (National Oceanic and Atmospheric Administration)
//  Solar Calculations: https://gml.noaa.gov/grad/solcalc/calcdetails.html
//
//  This implementation is fully self-contained and works offline, making it ideal for
//  schedule-based dimming that doesn't require internet access or location services API.
//

import Foundation

/// Calculates sunrise and sunset times using the NOAA solar position algorithm.
///
/// The algorithm accounts for:
/// - Earth's axial tilt (obliquity of the ecliptic)
/// - Orbital eccentricity (elliptical orbit)
/// - Atmospheric refraction (adds ~34 arcminutes to visible horizon)
/// - Equation of time (solar vs clock time difference)
///
/// Atmospheric refraction: The zenith angle is set to 90.833° instead of 90° to account
/// for atmospheric refraction at the horizon. This matches the standard definition of
/// sunrise/sunset (when the sun's upper limb appears to touch the horizon).
///
/// Polar regions: Returns nil for both sunrise and sunset when the sun doesn't rise or set
/// (polar day in summer, polar night in winter). Schedules using sunrise/sunset triggers
/// won't fire in these conditions.
enum SolarCalculator {
    /// Calculates sunrise and sunset for a given location and date.
    ///
    /// - Parameters:
    ///   - latitude: Latitude in degrees (positive north, negative south)
    ///   - longitude: Longitude in degrees (positive east, negative west)
    ///   - date: The calendar date to calculate for
    ///   - timeZone: The time zone for the result dates (defaults to current)
    /// - Returns: Tuple of sunrise and sunset dates, or (nil, nil) for polar day/night
    static func sunriseSunset(
        latitude: Double,
        longitude: Double,
        date: Date,
        timeZone: TimeZone = .current
    ) -> (sunrise: Date?, sunset: Date?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        // Julian Day Number
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        let julianDay = Double(jdn) - 0.5

        // Julian century from J2000.0
        let julianCentury = (julianDay - 2451545.0) / 36525.0

        // Solar coordinates
        let geomMeanLongSun = fmod(280.46646 + julianCentury * (36000.76983 + 0.0003032 * julianCentury), 360.0)
        let geomMeanAnomSun = 357.52911 + julianCentury * (35999.05029 - 0.0001537 * julianCentury)
        let eccentEarthOrbit = 0.016708634 - julianCentury * (0.000042037 + 0.0000001267 * julianCentury)

        let anomRad = geomMeanAnomSun * .pi / 180.0
        let sunEqOfCenter = sin(anomRad) * (1.914602 - julianCentury * (0.004817 + 0.000014 * julianCentury))
            + sin(2.0 * anomRad) * (0.019993 - 0.000101 * julianCentury)
            + sin(3.0 * anomRad) * 0.000289

        let sunTrueLong = geomMeanLongSun + sunEqOfCenter
        let sunAppLong = sunTrueLong - 0.00569 - 0.00478 * sin((125.04 - 1934.136 * julianCentury) * .pi / 180.0)

        // Obliquity of the ecliptic
        let meanObliqEcliptic = 23.0 + (26.0 + (21.448 - julianCentury * (46.815 + julianCentury * (0.00059 - julianCentury * 0.001813))) / 60.0) / 60.0
        let obliqCorr = meanObliqEcliptic + 0.00256 * cos((125.04 - 1934.136 * julianCentury) * .pi / 180.0)

        // Solar declination
        let sunDeclination = asin(sin(obliqCorr * .pi / 180.0) * sin(sunAppLong * .pi / 180.0)) * 180.0 / .pi

        // Equation of time (minutes)
        let obliqCorrRad = obliqCorr * .pi / 180.0
        let y2 = tan(obliqCorrRad / 2.0) * tan(obliqCorrRad / 2.0)
        let longRad = geomMeanLongSun * .pi / 180.0
        let eqOfTime = 4.0 * (y2 * sin(2.0 * longRad)
            - 2.0 * eccentEarthOrbit * sin(anomRad)
            + 4.0 * eccentEarthOrbit * y2 * sin(anomRad) * cos(2.0 * longRad)
            - 0.5 * y2 * y2 * sin(4.0 * longRad)
            - 1.25 * eccentEarthOrbit * eccentEarthOrbit * sin(2.0 * anomRad)) * 180.0 / .pi

        // Hour angle calculation for sunrise/sunset
        // Zenith = 90.833 degrees to account for atmospheric refraction at the horizon:
        //   90.0° = geometric horizon (sun's center at horizon)
        //   +0.833° = atmospheric refraction (~34 arcminutes)
        // This matches the standard definition where sunrise/sunset occurs when the sun's
        // upper limb appears to touch the horizon as seen by an observer at sea level.
        let latRad = latitude * .pi / 180.0
        let declRad = sunDeclination * .pi / 180.0
        let zenith = 90.833 * .pi / 180.0

        let cosHourAngle = (cos(zenith) / (cos(latRad) * cos(declRad))) - tan(latRad) * tan(declRad)

        // Check for polar day/night: if cosHourAngle is outside [-1, 1], acos is undefined
        // This occurs in polar regions where the sun doesn't rise (polar night) or doesn't
        // set (polar day) on this date.
        guard cosHourAngle >= -1.0 && cosHourAngle <= 1.0 else {
            return (sunrise: nil, sunset: nil)
        }

        let hourAngle = acos(cosHourAngle) * 180.0 / .pi

        // Time zone offset in hours
        let tzOffset = Double(timeZone.secondsFromGMT(for: date)) / 3600.0

        // Solar noon (minutes from midnight UTC)
        let solarNoon = (720.0 - 4.0 * longitude - eqOfTime + tzOffset * 60.0)

        // Sunrise and sunset in minutes from midnight local time
        let sunriseMinutes = solarNoon - hourAngle * 4.0
        let sunsetMinutes = solarNoon + hourAngle * 4.0

        // Convert to Date objects
        let startOfDay = calendar.startOfDay(for: date)
        let sunrise = startOfDay.addingTimeInterval(sunriseMinutes * 60.0)
        let sunset = startOfDay.addingTimeInterval(sunsetMinutes * 60.0)

        return (sunrise: sunrise, sunset: sunset)
    }
}
