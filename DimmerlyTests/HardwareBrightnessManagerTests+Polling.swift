//
//  HardwareBrightnessManagerTests+Polling.swift
//  DimmerlyTests
//
//  Tests that DDC polling and capability probing keep at most one read or probe per
//  display on the DDC queue, and that one poll of a display runs as one read batch.
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

    /// Records the read batches the manager opens and the reads made inside them.
    final class ReadBatchRecorder: @unchecked Sendable {
        enum Event: Equatable {
            case begin(CGDirectDisplayID)
            case read(VCPCode)
            case end
        }

        private let lock = NSLock()
        private var recordedEvents: [Event] = []

        var events: [Event] {
            lock.withLock { recordedEvents }
        }

        func record(_ event: Event) {
            lock.withLock { recordedEvents.append(event) }
        }
    }

    /// Wraps the mock interface so batch boundaries become visible to tests.
    struct BatchRecordingDDCInterface: DDCInterface {
        let base: MockDDCInterface
        let recorder: ReadBatchRecorder

        func read(vcp: VCPCode, for displayID: CGDirectDisplayID) -> DDCReadResult? {
            base.read(vcp: vcp, for: displayID)
        }

        func withReadBatch<Result>(
            for displayID: CGDirectDisplayID,
            _ body: (_ read: (VCPCode) -> DDCReadResult?) -> Result
        ) -> Result {
            recorder.record(.begin(displayID))
            defer { recorder.record(.end) }
            return body { vcp in
                recorder.record(.read(vcp))
                return base.read(vcp: vcp, for: displayID)
            }
        }

        func write(vcp: VCPCode, value: UInt16, for displayID: CGDirectDisplayID) -> Bool {
            base.write(vcp: vcp, value: value, for: displayID)
        }

        func probeCapabilities(
            for displayID: CGDirectDisplayID,
            skippingBrightness: Bool
        ) -> HardwareDisplayCapability {
            base.probeCapabilities(for: displayID, skippingBrightness: skippingBrightness)
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

        /// One poll of a display is one read batch, so the transport is looked up once
        /// for all of its codes, and the next poll starts a new batch.
        func testPollReadsAllCodesOfADisplayInOneBatch() async {
            let firstPublication = expectation(description: "First poll published")
            let secondPublication = expectation(description: "Second poll published")
            let recorder = ReadBatchRecorder()
            var mock = MockDDCInterface()
            mock.readHandler = { _, _ in DDCReadResult(currentValue: 20, maxValue: 100) }
            let manager = HardwareBrightnessManager(
                forTesting: true,
                ddcInterface: BatchRecordingDDCInterface(base: mock, recorder: recorder)
            )
            var publications = 0
            manager.readPublicationHookForTesting = {
                publications += 1
                if publications == 1 {
                    firstPublication.fulfill()
                } else if publications == 2 {
                    secondPublication.fulfill()
                }
            }
            manager.enable()
            manager.pollingInterval = 0.01
            manager.capabilities[2] = HardwareDisplayCapability(
                displayID: 2,
                supportsDDC: true,
                supportedCodes: [.brightness, .contrast, .volume],
                maxBrightness: 100,
                maxContrast: 100,
                maxVolume: 100
            )

            manager.startPolling()
            await fulfillment(of: [firstPublication, secondPublication], timeout: 1, enforceOrder: true)
            manager.stopPolling()
            await manager.disable()

            let onePoll: [ReadBatchRecorder.Event] = [
                .begin(2), .read(.brightness), .read(.contrast), .read(.volume), .end,
            ]
            XCTAssertEqual(Array(recorder.events.prefix(onePoll.count * 2)), onePoll + onePoll)
        }
    }

#endif // !APPSTORE
