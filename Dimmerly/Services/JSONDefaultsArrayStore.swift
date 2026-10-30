//
//  JSONDefaultsArrayStore.swift
//  Dimmerly
//
//  Persists a Codable array as JSON under a single UserDefaults key. Shared by
//  PresetManager and ScheduleManager.
//

import Foundation
import OSLog

/// Stores an array of `Element` as JSON data in `UserDefaults`.
///
/// Loading decodes one element at a time, so a single element this build cannot decode
/// (corruption, or a newer build's enum case after a downgrade) does not discard the rest.
/// When anything is dropped, the original data is copied to `backupKey` before the next save
/// can replace it. An existing backup is kept: it was taken before any lossy save, so it holds
/// at least as much as the current data.
struct JSONDefaultsArrayStore<Element: Codable> {
    let key: String
    let backupKey: String
    let defaults: UserDefaults
    let logger: Logger
    /// Plural noun used in encode-failure log messages, e.g. "brightness presets".
    let elementsDescription: String

    private struct LossyElement: Decodable {
        let value: Element?

        init(from decoder: Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    /// Returns every element that decodes, backing up the raw data if any element (or the
    /// whole payload) could not be read. Returns an empty array when nothing is stored.
    func load() -> [Element] {
        guard let data = defaults.data(forKey: key) else { return [] }

        let elements: [LossyElement]
        do {
            elements = try JSONDecoder().decode([LossyElement].self, from: data)
        } catch {
            logger.error(
                "Stored \(key, privacy: .public) is unreadable: \(error.localizedDescription, privacy: .public)"
            )
            backUp(data)
            return []
        }

        let values = elements.compactMap(\.value)
        let failedCount = elements.count - values.count
        if failedCount > 0 {
            logger.error(
                """
                Dropped \(failedCount, privacy: .public) of \(elements.count, privacy: .public) \
                undecodable elements in \(key, privacy: .public)
                """
            )
            backUp(data)
        }
        return values
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
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
    }

    private func backUp(_ data: Data) {
        guard defaults.data(forKey: backupKey) == nil else {
            logger.notice("Keeping the existing backup of \(key, privacy: .public) in \(backupKey, privacy: .public)")
            return
        }
        defaults.set(data, forKey: backupKey)
        logger.notice("Backed up the original \(key, privacy: .public) to \(backupKey, privacy: .public)")
    }
}
