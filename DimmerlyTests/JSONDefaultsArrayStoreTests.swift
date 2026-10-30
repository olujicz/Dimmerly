//
//  JSONDefaultsArrayStoreTests.swift
//  DimmerlyTests
//

@testable import Dimmerly
import OSLog
import XCTest

final class JSONDefaultsArrayStoreTests: XCTestCase {
    private struct Item: Codable, Equatable {
        let name: String
        let level: Double
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: JSONDefaultsArrayStore<Item>!

    override func setUp() {
        super.setUp()
        suiteName = "JSONDefaultsArrayStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = JSONDefaultsArrayStore(
            key: "items",
            backupKey: "itemsBackup",
            defaults: defaults,
            logger: Logger(subsystem: "rs.in.olujic.dimmerly.tests", category: "JSONDefaultsArrayStoreTests"),
            elementsDescription: "test items"
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadReturnsEmptyWhenNothingIsStored() {
        XCTAssertEqual(store.load(), [])
        XCTAssertNil(defaults.data(forKey: "itemsBackup"))
    }

    func testSaveThenLoadRoundTripsInOrder() {
        let items = [Item(name: "a", level: 0.25), Item(name: "b", level: 0.75)]

        XCTAssertTrue(store.save(items))

        XCTAssertEqual(store.load(), items)
        XCTAssertNil(defaults.data(forKey: "itemsBackup"))
    }

    func testLoadKeepsDecodableElementsAndBacksUpRawData() {
        let raw = Data(#"[{"name":"a","level":0.5},{"name":"broken"},{"name":"c","level":1}]"#.utf8)
        defaults.set(raw, forKey: "items")

        XCTAssertEqual(store.load(), [Item(name: "a", level: 0.5), Item(name: "c", level: 1)])
        XCTAssertEqual(defaults.data(forKey: "itemsBackup"), raw)
        XCTAssertEqual(defaults.data(forKey: "items"), raw)
    }

    func testFailedEncodeLeavesStoredDataUnchanged() {
        let items = [Item(name: "a", level: 0.5)]
        XCTAssertTrue(store.save(items))

        XCTAssertFalse(store.save([Item(name: "nan", level: .nan)]))

        XCTAssertEqual(store.load(), items)
    }
}
