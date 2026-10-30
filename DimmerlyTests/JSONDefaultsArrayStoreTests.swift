//
//  JSONDefaultsArrayStoreTests.swift
//  DimmerlyTests
//

@testable import Dimmerly
import OSLog
import XCTest

final class JSONDefaultsArrayStoreTests: XCTestCase {
    private struct Item: Codable, Equatable, Identifiable {
        let name: String
        let level: Double

        var id: String {
            name
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: JSONDefaultsArrayStore<Item>!

    override func setUp() {
        super.setUp()
        suiteName = "JSONDefaultsArrayStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = makeStore()
    }

    private func makeStore(maxCount: Int? = nil) -> JSONDefaultsArrayStore<Item> {
        JSONDefaultsArrayStore(
            key: "items",
            backupKey: "itemsBackup",
            defaults: defaults,
            logger: Logger(subsystem: "rs.in.olujic.dimmerly.tests", category: "JSONDefaultsArrayStoreTests"),
            elementsDescription: "test items",
            maxCount: maxCount
        )
    }

    private func backupString() -> String? {
        defaults.data(forKey: "itemsBackup").flatMap { String(bytes: $0, encoding: .utf8) }
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

    func testLoadKeepsDecodableElementsAndBacksUpTheUndecodableOnes() {
        let raw = Data(#"[{"name":"a","level":0.5},{"name":"broken"},{"name":"c","level":1}]"#.utf8)
        defaults.set(raw, forKey: "items")

        XCTAssertEqual(store.load(), [Item(name: "a", level: 0.5), Item(name: "c", level: 1)])
        XCTAssertEqual(backupString(), #"[{"name":"broken"}]"#)
        XCTAssertEqual(defaults.data(forKey: "items"), raw, "Loading must not rewrite elements it could not read")
    }

    func testRepeatedLossyLoadsKeepOneCopyOfEachUndecodableElement() {
        defaults.set(Data(#"[{"name":"a","level":0.5},{"name":"broken"}]"#.utf8), forKey: "items")

        _ = store.load()
        XCTAssertEqual(store.load(), [Item(name: "a", level: 0.5)])

        XCTAssertEqual(backupString(), #"[{"name":"broken"}]"#)
    }

    func testDeletedElementIsNotRestoredAfterALossyLoad() {
        let raw = Data(#"[{"name":"a","level":0.5},{"name":"broken"},{"name":"c","level":1}]"#.utf8)
        defaults.set(raw, forKey: "items")
        _ = store.load()

        XCTAssertTrue(store.save([Item(name: "c", level: 1)]))

        XCTAssertEqual(store.load(), [Item(name: "c", level: 1)])
        XCTAssertEqual(backupString(), #"[{"name":"broken"}]"#)
    }

    func testLoadRestoresBackupElementsThatNowDecodeAndDeletesTheBackup() throws {
        XCTAssertTrue(store.save([Item(name: "a", level: 0.5)]))
        defaults.set(Data(#"[{"name":"b","level":0.25},{"name":"c","level":1}]"#.utf8), forKey: "itemsBackup")

        let expected = [Item(name: "a", level: 0.5), Item(name: "b", level: 0.25), Item(name: "c", level: 1)]
        XCTAssertEqual(store.load(), expected)
        XCTAssertNil(defaults.data(forKey: "itemsBackup"))
        let saved = try JSONDecoder().decode([Item].self, from: XCTUnwrap(defaults.data(forKey: "items")))
        XCTAssertEqual(saved, expected, "Restored elements should be saved right away")
    }

    func testRestoreKeepsCurrentElementsWhenTheBackupHasTheSameID() {
        let current = Data(#"[{"level":0.5,"name":"a"}]"#.utf8)
        defaults.set(current, forKey: "items")
        defaults.set(Data(#"[{"name":"a","level":0.9}]"#.utf8), forKey: "itemsBackup")

        XCTAssertEqual(store.load(), [Item(name: "a", level: 0.5)])
        XCTAssertNil(defaults.data(forKey: "itemsBackup"))
        XCTAssertEqual(defaults.data(forKey: "items"), current, "Nothing was restored, so nothing should be saved")
    }

    func testRestoreKeepsBackupElementsThatStillCannotBeDecoded() {
        XCTAssertTrue(store.save([Item(name: "a", level: 0.5)]))
        defaults.set(Data(#"[{"name":"b","level":0.25},{"name":"broken"}]"#.utf8), forKey: "itemsBackup")

        XCTAssertEqual(store.load(), [Item(name: "a", level: 0.5), Item(name: "b", level: 0.25)])
        XCTAssertEqual(backupString(), #"[{"name":"broken"}]"#)
    }

    func testRestoreStopsAtMaxCountAndKeepsTheRestInTheBackup() {
        let limitedStore = makeStore(maxCount: 2)
        XCTAssertTrue(limitedStore.save([Item(name: "a", level: 0.5)]))
        defaults.set(Data(#"[{"level":0.25,"name":"b"},{"level":1,"name":"c"}]"#.utf8), forKey: "itemsBackup")

        XCTAssertEqual(limitedStore.load(), [Item(name: "a", level: 0.5), Item(name: "b", level: 0.25)])
        XCTAssertEqual(backupString(), #"[{"level":1,"name":"c"}]"#)
    }

    func testUnreadableBackupIsKeptUntouched() {
        XCTAssertTrue(store.save([Item(name: "a", level: 0.5)]))
        let backup = Data("not json".utf8)
        defaults.set(backup, forKey: "itemsBackup")

        XCTAssertEqual(store.load(), [Item(name: "a", level: 0.5)])
        XCTAssertEqual(defaults.data(forKey: "itemsBackup"), backup)
    }

    func testUnreadableDataIsBackedUpAsIs() {
        let raw = Data("not json".utf8)
        defaults.set(raw, forKey: "items")

        XCTAssertEqual(store.load(), [])
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
