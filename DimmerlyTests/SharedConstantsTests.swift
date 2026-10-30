//
//  SharedConstantsTests.swift
//  DimmerlyTests
//
//  Unit tests for shared app-group resolution and widget action bookkeeping.
//

@testable import Dimmerly
import XCTest

final class SharedConstantsTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "SharedConstantsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testResolvedAppGroupIDUsesProvidedTeamPrefix() {
        XCTAssertEqual(
            SharedConstants.resolvedAppGroupID(
                teamIdentifierPrefix: "TEAM123.",
                bundleIdentifier: "rs.in.olujic.dimmerly"
            ),
            "TEAM123.rs.in.olujic.dimmerly"
        )
    }

    func testResolvedAppGroupIDAvoidsDoubleDot() {
        XCTAssertEqual(
            SharedConstants.resolvedAppGroupID(
                teamIdentifierPrefix: "TEAM123",
                bundleIdentifier: "rs.in.olujic.dimmerly"
            ),
            "TEAM123.rs.in.olujic.dimmerly"
        )
    }

    func testWidgetActionOutcomeReportsWhatTheAppAcknowledged() {
        let succeeded = UUID()
        let failed = UUID()
        let pending = UUID()

        SharedConstants.acknowledgeWidgetAction(succeeded, succeeded: true, in: defaults)
        SharedConstants.acknowledgeWidgetAction(failed, succeeded: false, in: defaults)

        XCTAssertEqual(SharedConstants.widgetActionOutcome(succeeded, in: defaults), .succeeded)
        XCTAssertEqual(SharedConstants.widgetActionOutcome(failed, in: defaults), .failed)
        XCTAssertNil(SharedConstants.widgetActionOutcome(pending, in: defaults))
    }

    /// An acknowledgement written after the extension stopped waiting, or a request left by an
    /// extension that was killed mid-wait, is never removed by its own exchange. Launch clears
    /// them, but keeps a request that is still live: the extension may have stored it while
    /// LaunchServices was still starting the app.
    func testDiscardingStaleWidgetActionKeysKeepsLiveRequestsOnly() throws {
        let now = Date()
        let live = WidgetActionRequest(command: .setDimming(true), expiresAt: now.addingTimeInterval(5))
        let expired = WidgetActionRequest(command: .dimDisplays, expiresAt: now)
        try SharedConstants.storeWidgetActionRequest(live, in: defaults)
        try SharedConstants.storeWidgetActionRequest(expired, in: defaults)
        defaults.set(Data([1, 2, 3]), forKey: "widgetActionRequest.\(UUID().uuidString)")
        let orphanedAcknowledgement = UUID()
        SharedConstants.acknowledgeWidgetAction(orphanedAcknowledgement, succeeded: true, in: defaults)
        SharedConstants.publishControlState(true, forKey: SharedConstants.controlDimStateKey, in: defaults)

        SharedConstants.discardStaleWidgetActionKeys(in: defaults, now: now)

        let remainingKeys = Set((defaults.persistentDomain(forName: defaultsSuiteName) ?? [:]).keys)
        XCTAssertEqual(
            remainingKeys,
            ["widgetActionRequest.\(live.id.uuidString)", SharedConstants.controlDimStateKey]
        )
        XCTAssertNil(SharedConstants.widgetActionOutcome(orphanedAcknowledgement, in: defaults))
        XCTAssertEqual(
            SharedConstants.consumeWidgetActionRequest(live.id, from: defaults, now: now)?.command,
            .setDimming(true)
        )
    }

    func testDiscardingStaleWidgetActionKeysWithoutSharedDefaultsIsANoOp() {
        SharedConstants.discardStaleWidgetActionKeys(in: nil)
    }
}
