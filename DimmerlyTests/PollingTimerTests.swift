//
//  PollingTimerTests.swift
//  DimmerlyTests
//
//  Unit tests for PollingTimer's tick delivery and shutdown.
//

@testable import Dimmerly
import XCTest

@MainActor
final class PollingTimerTests: XCTestCase {
    private var timer: PollingTimer!
    private var tickCount = 0

    override func setUp() async throws {
        timer = PollingTimer()
        tickCount = 0
    }

    override func tearDown() async throws {
        timer?.stop()
        timer = nil
    }

    private func startCounting() {
        timer.start(interval: 0.01) { [weak self] in
            self?.tickCount += 1
        }
    }

    /// Spins the main run loop so scheduled timers get a chance to fire.
    private func runMainLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    func testTicksRepeatWhileRunning() {
        startCounting()
        runMainLoop(for: 0.1)

        XCTAssertTrue(timer.isRunning)
        XCTAssertGreaterThan(tickCount, 1)
    }

    func testStopPreventsFurtherTicks() {
        startCounting()
        timer.stop()
        runMainLoop(for: 0.1)

        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(tickCount, 0)
    }

    func testRestartReplacesThePreviousTimer() {
        var replacedTicks = 0
        timer.start(interval: 0.01) { replacedTicks += 1 }
        startCounting()
        runMainLoop(for: 0.1)

        XCTAssertEqual(replacedTicks, 0)
        XCTAssertGreaterThan(tickCount, 0)
    }

    func testReleasingTheOwnerStopsTicks() {
        var ticks = 0
        timer.start(interval: 0.01) { ticks += 1 }
        timer = nil
        runMainLoop(for: 0.1)

        XCTAssertEqual(ticks, 0)
    }
}
