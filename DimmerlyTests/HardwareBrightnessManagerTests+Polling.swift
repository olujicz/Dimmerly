//
//  HardwareBrightnessManagerTests+Polling.swift
//  DimmerlyTests
//
//  Tests that DDC polling and capability probing keep at most one read or probe per
//  display on the DDC queue.
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

    final class CountingBlockingDDCProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let firstCallCanFinish = DispatchSemaphore(value: 0)
        private let firstCallStarted: XCTestExpectation
        private let supportsDDC: Bool
        private var calls = 0

        init(firstCallStarted: XCTestExpectation, supportsDDC: Bool = true) {
            self.firstCallStarted = firstCallStarted
            self.supportsDDC = supportsDDC
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        func probe(_ displayID: CGDirectDisplayID) -> HardwareDisplayCapability {
            let isFirstCall = lock.withLock {
                calls += 1
                return calls == 1
            }
            if isFirstCall {
                firstCallStarted.fulfill()
                _ = firstCallCanFinish.wait(timeout: .now() + 2)
            }
            guard supportsDDC else { return .notSupported(displayID: displayID) }
            return HardwareDisplayCapability(
                displayID: displayID,
                supportsDDC: true,
                supportedCodes: [.volume],
                maxBrightness: 0,
                maxContrast: 0,
                maxVolume: 100
            )
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

        // MARK: - Probe Deduplication

        private func makeProbingManager(
            probe: CountingBlockingDDCProbe,
            refreshed: XCTestExpectation
        ) -> HardwareBrightnessManager {
            refreshed.assertForOverFulfill = false
            var mock = MockDDCInterface()
            mock.probeHandler = { probe.probe($0) }
            let manager = HardwareBrightnessManager(
                forTesting: true,
                ddcInterface: mock,
                connectedExternalDisplayIDsProvider: { [1] },
                displayRefreshHandler: { refreshed.fulfill() }
            )
            manager.enable()
            return manager
        }

        func testProbeSkipsDisplayWhoseProbeIsStillRunning() async throws {
            let probeStarted = expectation(description: "First probe started")
            let refreshed = expectation(description: "Probe published")
            let probe = CountingBlockingDDCProbe(firstCallStarted: probeStarted)
            let manager = makeProbingManager(probe: probe, refreshed: refreshed)

            // Launch and the Settings toggle both refresh (which probes unprobed displays) and
            // then probe explicitly; reconfiguration callbacks refresh again before publication.
            manager.probeAllDisplays(force: false)
            await fulfillment(of: [probeStarted], timeout: 1)
            manager.probeAllDisplays(force: false)
            manager.probeAllDisplays(force: true)
            probe.releaseFirstCall()
            await fulfillment(of: [refreshed], timeout: 1)
            try await Task.sleep(for: .milliseconds(150))
            await manager.disable()

            XCTAssertEqual(probe.callCount, 1)
        }

        func testCompletedProbeDoesNotBlockTheNextOne() async throws {
            let probeStarted = expectation(description: "First probe started")
            let refreshed = expectation(description: "Probe published")
            let probe = CountingBlockingDDCProbe(firstCallStarted: probeStarted, supportsDDC: false)
            let manager = makeProbingManager(probe: probe, refreshed: refreshed)

            manager.probeAllDisplays(force: true)
            await fulfillment(of: [probeStarted], timeout: 1)
            probe.releaseFirstCall()
            await fulfillment(of: [refreshed], timeout: 1)
            manager.probeAllDisplays(force: true)
            try await Task.sleep(for: .milliseconds(150))
            await manager.disable()

            XCTAssertEqual(probe.callCount, 2)
        }

        func testProbeOfReconnectedDisplayIsNotSkipped() async throws {
            let probeStarted = expectation(description: "First probe started")
            let refreshed = expectation(description: "Probe published")
            let probe = CountingBlockingDDCProbe(firstCallStarted: probeStarted)
            let manager = makeProbingManager(probe: probe, refreshed: refreshed)

            manager.probeAllDisplays(force: false)
            await fulfillment(of: [probeStarted], timeout: 1)
            // The monitor drops off and comes back under the same ID before the probe returns.
            manager.removeDisplay(1)
            manager.probeAllDisplays(force: false)
            probe.releaseFirstCall()
            await fulfillment(of: [refreshed], timeout: 1)
            try await Task.sleep(for: .milliseconds(150))
            await manager.disable()

            XCTAssertEqual(probe.callCount, 2)
        }

        func testProbeAfterReenablingIsNotSkipped() async {
            let probeStarted = expectation(description: "First probe started")
            let refreshed = expectation(description: "Probe published")
            let probe = CountingBlockingDDCProbe(firstCallStarted: probeStarted)
            let manager = makeProbingManager(probe: probe, refreshed: refreshed)

            manager.probeAllDisplays(force: false)
            await fulfillment(of: [probeStarted], timeout: 1)
            let disabling = Task { await manager.disable() }
            while !manager.isDisabling {
                await Task.yield()
            }
            manager.enable()
            manager.probeAllDisplays(force: true)
            probe.releaseFirstCall()
            await disabling.value
            await fulfillment(of: [refreshed], timeout: 1)
            await manager.disable()

            XCTAssertEqual(probe.callCount, 2)
            XCTAssertNotNil(manager.capability(for: 1))
        }

        func testProbeAfterBrightnessOwnershipChangeIsNotSkipped() async {
            let probeStarted = expectation(description: "First probe started")
            let refreshed = expectation(description: "Probe published")
            let probe = CountingBlockingDDCProbe(firstCallStarted: probeStarted)
            let manager = makeProbingManager(probe: probe, refreshed: refreshed)

            manager.probeAllDisplays(force: false)
            await fulfillment(of: [probeStarted], timeout: 1)
            // The running probe is abandoned, so its replacement must not wait for it.
            manager.applyRuntimeSettings(
                controlMode: .softwareOnly,
                pollingInterval: 5,
                writeDelayMilliseconds: 50
            )
            manager.probeAllDisplays(force: true)
            probe.releaseFirstCall()
            await fulfillment(of: [refreshed], timeout: 1)
            await manager.disable()

            XCTAssertEqual(probe.callCount, 2)
        }

        func testRemoveDisplayCancelsAutomaticProbeRetry() async throws {
            let probeStarted = expectation(description: "First probe started")
            let refreshed = expectation(description: "Probe published")
            let probe = CountingBlockingDDCProbe(firstCallStarted: probeStarted, supportsDDC: false)
            let manager = makeProbingManager(probe: probe, refreshed: refreshed)

            manager.probeAllDisplays(force: false)
            await fulfillment(of: [probeStarted], timeout: 1)
            probe.releaseFirstCall()
            await fulfillment(of: [refreshed], timeout: 1)
            manager.removeDisplay(1)
            // The first automatic retry would run 250 ms after the unsupported result.
            try await Task.sleep(for: .milliseconds(600))
            await manager.disable()

            XCTAssertEqual(probe.callCount, 1)
        }

        func testDisplayUnpluggedDuringFirstProbeIsCleanedUpAndReprobedOnReconnect() async throws {
            let probeStarted = expectation(description: "First probe started")
            let refreshed = expectation(description: "Probe finished")
            refreshed.assertForOverFulfill = false
            let probe = CountingBlockingDDCProbe(firstCallStarted: probeStarted)
            var connectedIDs: [CGDirectDisplayID] = [1, 2]
            var mock = MockDDCInterface()
            mock.probeHandler = { probe.probe($0) }
            let manager = HardwareBrightnessManager(
                forTesting: true,
                ddcInterface: mock,
                connectedExternalDisplayIDsProvider: { connectedIDs },
                displayRefreshHandler: { refreshed.fulfill() }
            )
            manager.enable()
            let otherCapability = HardwareDisplayCapability(
                displayID: 2, supportsDDC: true, supportedCodes: [.brightness],
                maxBrightness: 100, maxContrast: 0, maxVolume: 0
            )
            manager.capabilities[2] = otherCapability

            manager.probeAllDisplays(force: false)
            await fulfillment(of: [probeStarted], timeout: 1)
            // Display 1 is unplugged before its first probe returns, so it has no capabilities
            // yet. A refresh must still clean it up, as it does for display 2's departure.
            connectedIDs = [2]
            manager.removeDisplays(notIn: Set(connectedIDs))
            XCTAssertNil(manager.capability(for: 1))
            XCTAssertEqual(manager.capability(for: 2), otherCapability, "A connected display keeps its state")

            // It comes back under the same ID while the old probe is still stuck on the bus.
            connectedIDs = [1, 2]
            manager.probeAllDisplays(force: false)
            probe.releaseFirstCall()
            await fulfillment(of: [refreshed], timeout: 1)
            try await Task.sleep(for: .milliseconds(150))
            await manager.disable()

            XCTAssertEqual(probe.callCount, 2, "The reconnected display needs a probe of its own")
            XCTAssertEqual(manager.capability(for: 1)?.supportedCodes, [.volume])
        }
    }

#endif // !APPSTORE
