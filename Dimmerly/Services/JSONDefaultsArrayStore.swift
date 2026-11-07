//
//  JSONDefaultsArrayStore.swift
//  Dimmerly
//
//  Persists a Codable array as JSON under a single UserDefaults key. Shared by
//  PresetManager and ScheduleManager.
//

import CryptoKit
import Foundation
import OSLog

/// Stores an array of `Element` as JSON data in `UserDefaults`.
///
/// Loading decodes one element at a time, so a single element this build cannot decode
/// (corruption, or a newer build's enum case after a downgrade) does not discard the rest.
/// Elements that cannot be decoded are copied to `backupKey` before the next save can replace
/// them. The backup only ever holds elements that are not in the stored list yet: on every
/// load, backup elements that this build can decode are restored (appended after the current
/// elements, skipping ids that are already present) and removed from the backup, and the
/// backup is deleted once nothing is left in it. Keeping only unrecovered elements means a
/// decodable element the user deletes later is not brought back from the backup.
///
/// A payload that is unreadable as a whole cannot be split into elements, so it is kept as is
/// in a separate list under `unreadableBackupKey` for manual recovery, next to any element
/// backup. Earlier builds stored such a payload under `backupKey` itself; a load moves it to
/// `unreadableBackupKey` so `backupKey` can hold elements again.
struct JSONDefaultsArrayStore<Element: Codable & Identifiable> {
    let key: String
    let backupKey: String
    let defaults: UserDefaults
    let logger: Logger
    /// Plural noun used in encode-failure log messages, e.g. "brightness presets".
    let elementsDescription: String
    /// The most elements a load may return after restoring from the backup. Backup elements
    /// that do not fit stay in the backup. `nil` means no limit.
    var maxCount: Int?

    /// Holds every distinct payload that was unreadable as a whole, as an array of `Data`.
    var unreadableBackupKey: String {
        backupKey + "Unreadable"
    }

    /// Returns every element that decodes, plus any backup elements that can now be restored.
    /// Undecodable elements are moved to the backup. When anything is restored, the combined
    /// list is saved immediately. Returns an empty array when nothing is stored.
    func load() -> [Element] {
        var values: [Element] = []
        var undecodable: [Data] = []

        if let data = defaults.data(forKey: key) {
            do {
                for element in try Self.rawElements(of: data) {
                    if let value = try? JSONDecoder().decode(Element.self, from: element) {
                        values.append(value)
                    } else {
                        undecodable.append(element)
                    }
                }
            } catch {
                logger.error(
                    "Stored \(key, privacy: .public) is unreadable: \(error.localizedDescription, privacy: .private)"
                )
                backUpUnreadable(data)
                return values
            }

            if !undecodable.isEmpty {
                logger.error(
                    """
                    Dropped \(undecodable.count, privacy: .public) of \
                    \(values.count + undecodable.count, privacy: .public) \
                    undecodable elements in \(key, privacy: .public)
                    """
                )
            }
        }

        return restoringFromBackup(values, addingToBackup: undecodable)
    }

    /// Encodes `elements` and writes them to `key`. Returns `false` (after logging) if encoding
    /// fails, in which case the stored data is left unchanged.
    @discardableResult
    func save(_ elements: [Element]) -> Bool {
        do {
            let data = try JSONEncoder().encode(elements)
            defaults.set(data, forKey: key)
            return true
        } catch {
            logger.error(
                """
                Failed to encode \(elementsDescription, privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """
            )
            return false
        }
    }

    // MARK: - Backup

    /// Merges `undecodable` into the backup, restores every backup element this build can now
    /// decode, and leaves only the elements that are still missing from the list in the backup.
    private func restoringFromBackup(_ values: [Element], addingToBackup undecodable: [Data]) -> [Element] {
        var storedBackup = defaults.data(forKey: backupKey)
        var pending: [Data] = []
        if let backup = storedBackup {
            do {
                pending = try Self.rawElements(of: backup)
            } catch {
                // An earlier build's backup of a payload that was unreadable as a whole. Move
                // it to the list of unreadable payloads so this key can hold elements again.
                guard backUpUnreadable(backup) else { return values }
                defaults.removeObject(forKey: backupKey)
                storedBackup = nil
                logger.notice(
                    """
                    Moved the unreadable backup of \(key, privacy: .public) from \
                    \(backupKey, privacy: .public) to \(unreadableBackupKey, privacy: .public)
                    """
                )
            }
        }
        for element in undecodable where !pending.contains(element) {
            pending.append(element)
        }
        guard storedBackup != nil || !pending.isEmpty else { return values }

        var result = values
        var ids = Set(values.map(\.id))
        var remaining: [Data] = []
        for element in pending {
            guard let value = try? JSONDecoder().decode(Element.self, from: element) else {
                remaining.append(element)
                continue
            }
            guard !ids.contains(value.id) else { continue }
            if let maxCount, result.count >= maxCount {
                remaining.append(element)
                continue
            }
            result.append(value)
            ids.insert(value.id)
        }

        let restoredCount = result.count - values.count
        if restoredCount > 0 {
            // Without a successful save the restored elements would be lost again, so keep
            // the backup as it is.
            guard save(result) else { return result }
            logger.notice(
                """
                Restored \(restoredCount, privacy: .public) elements of \(key, privacy: .public) \
                from \(backupKey, privacy: .public)
                """
            )
        }

        if remaining.isEmpty {
            if storedBackup != nil {
                defaults.removeObject(forKey: backupKey)
                logger.notice("Removed \(backupKey, privacy: .public); nothing is left to restore")
            }
        } else {
            let backup = Self.arrayData(of: remaining)
            if backup != storedBackup {
                defaults.set(backup, forKey: backupKey)
                logger.notice(
                    """
                    Backed up \(remaining.count, privacy: .public) unrestored elements of \
                    \(key, privacy: .public) in \(backupKey, privacy: .public)
                    """
                )
            }
        }
        return result
    }

    /// Adds a payload that is unreadable as a whole to the list under `unreadableBackupKey`,
    /// unless an identical payload is already there. If that key holds a value this build
    /// doesn't recognize, the value is left alone and the payload goes to a key of its own.
    @discardableResult
    private func backUpUnreadable(_ data: Data) -> Bool {
        let stored = defaults.object(forKey: unreadableBackupKey)
        guard stored == nil || stored is [Data] else {
            // Leave the unexpected value alone, but never let it cost this payload.
            // Named after the payload, so loading the same payload again adds nothing.
            let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            let fallbackKey = "\(unreadableBackupKey).\(digest)"
            defaults.set(data, forKey: fallbackKey)
            logger.error(
                """
                Unexpected value in \(unreadableBackupKey, privacy: .public); backed up the unreadable \
                \(key, privacy: .public) to \(fallbackKey, privacy: .public) instead
                """
            )
            return true
        }
        var payloads = stored as? [Data] ?? []
        guard !payloads.contains(data) else { return true }
        payloads.append(data)
        defaults.set(payloads, forKey: unreadableBackupKey)
        logger.notice(
            """
            Backed up the unreadable \(key, privacy: .public) to \(unreadableBackupKey, privacy: .public) \
            (\(payloads.count, privacy: .public) payloads kept)
            """
        )
        return true
    }

    /// Splits a JSON array into the JSON data of each element, with sorted keys so equal
    /// elements compare equal. Throws if `data` is not a JSON array.
    private static func rawElements(of data: Data) throws -> [Data] {
        guard let array = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try array.map {
            try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])
        }
    }

    /// Joins element JSON data into a JSON array.
    private static func arrayData(of elements: [Data]) -> Data {
        var data = Data("[".utf8)
        for (index, element) in elements.enumerated() {
            if index > 0 {
                data.append(Data(",".utf8))
            }
            data.append(element)
        }
        data.append(Data("]".utf8))
        return data
    }
}
