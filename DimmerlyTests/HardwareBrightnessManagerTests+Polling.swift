//
//  HardwareBrightnessManagerTests+Polling.swift
//  DimmerlyTests
//
//  Tests that DDC polling keeps at most one read per display on the DDC queue.
//

@testable import Dimmerly
import XCTest

#if !APPSTORE

    final class CountingBlockingDDCRead: @unchecked Sendable {
        private let lock = NSLock()
        private let firstCallCanFinish = DispatchSemaphore(value: 0)
        private let firstCallStarted: XCTestExpectation
        private var calls = 0

        init(firstCallStarted: XCTestExpectation) {
            self.firstCallStarted = firstCallStarted
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        func read() -> DDCReadResult {
            let isFirstCall = lock.withLock {
                calls += 1
                return calls == 1
            }
            if isFirstCall {
                firstCallStarted.fulfill()
                _ = firstCallCanFinish.wait(timeout: .now() + 2)
            }
            return DDCReadResult(currentValue: 20, maxValue: 100)
        }

        func releaseFirstCall() {
            firstCallCanFinish.signal()
        }
    }

    @MainActor
    extension HardwareBrightnessManagerTests {
        func testPollingSkipsDisplayWhosePreviousReadIsStillRunning() async throws {
            let readStarted = expectation(description: "First read started")
            let countingRead = CountingBlockingDDCRead(firstCallStarted: readStarted)
            var mock = MockDDCInterface()
            mock.readHandler = { _, _ in countingRead.read() }
            let manager = HardwareBrightnessManager(forTesting: true, ddcInterface: mock)
            manager.enable()
            manager.pollingInterval = 0.01
            manager.capabilities[1] = HardwareDisplayCapability(
                displayID: 1,
                supportsDDC: true,
                supportedCodes: [.volume],
                maxBrightness: 0,
                maxContrast: 0,
                maxVolume: 100
            )

            manager.startPolling()
            await fulfillment(of: [readStarted], timeout: 1)
            // Let many poll ticks pass while the first read is stuck on the DDC queue.
            try await Task.sleep(for: .milliseconds(150))
            manager.stopPolling()
            countingRead.releaseFirstCall()
            // Give any backlog queued behind the first read time to run before checking;
            // disabling first would invalidate the session and hide the extra reads.
            try await Task.sleep(for: .milliseconds(150))
            await manager.disable()

            XCTAssertEqual(countingRead.callCount, 1)
        }

        func testPollingResumesAfterPreviousReadFinishes() async {
            let firstPublication = expectation(description: "First read published")
            let secondPublication = expectation(description: "Second read published")
            var publications = 0
            var mock = MockDDCInterface()
            mock.readHandler = { _, _ in DDCReadResult(currentValue: 20, maxValue: 100) }
            let manager = HardwareBrightnessManager(forTesting: true, ddcInterface: mock)
            manager.readPublicationHookForTesting = {
                publications += 1
                if publications == 1 {
                    firstPublication.fulfill()
                }
                if publications == 2 {
                    secondPublication.fulfill()
                }
            }
            manager.enable()
            manager.pollingInterval = 0.01
            manager.capabilities[1] = HardwareDisplayCapability(
                displayID: 1,
                supportsDDC: true,
                supportedCodes: [.volume],
                maxBrightness: 0,
                maxContrast: 0,
                maxVolume: 100
            )

            manager.startPolling()
            await fulfillment(of: [firstPublication, secondPublication], timeout: 1, enforceOrder: true)
            manager.stopPolling()
        }
    }

#endif // !APPSTORE
