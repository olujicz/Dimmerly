//
//  DDCSessionGate.swift
//  Dimmerly
//

#if !APPSTORE

    import CoreGraphics
    import Foundation

    struct DDCSession: Equatable, Sendable {
        let generation: UInt64
    }

    final class DDCSessionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var enabled = false

        @discardableResult
        func beginEnabledSession() -> DDCSession {
            lock.withLock {
                generation &+= 1
                enabled = true
                return DDCSession(generation: generation)
            }
        }

        func capture() -> DDCSession? {
            lock.withLock {
                enabled ? DDCSession(generation: generation) : nil
            }
        }

        func isCurrent(_ session: DDCSession) -> Bool {
            lock.withLock {
                enabled && session.generation == generation
            }
        }

        func invalidate(_ session: DDCSession) {
            lock.withLock {
                guard enabled, session.generation == generation else { return }
                enabled = false
                generation &+= 1
            }
        }
    }

    /// Identifies one physical connection for a CoreGraphics display ID. The numeric ID may be
    /// reused after a disconnect, so queued DDC work must validate this token in addition to its
    /// global session.
    struct DDCDisplayConnectionToken: Equatable, Sendable {
        let displayID: CGDirectDisplayID
        let incarnation: UInt64
    }

    final class DDCDisplayConnectionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var incarnations: [CGDirectDisplayID: UInt64] = [:]

        func current(for displayID: CGDirectDisplayID) -> DDCDisplayConnectionToken {
            lock.withLock {
                DDCDisplayConnectionToken(
                    displayID: displayID,
                    incarnation: incarnations[displayID] ?? 0
                )
            }
        }

        @discardableResult
        func advance(for displayID: CGDirectDisplayID) -> DDCDisplayConnectionToken {
            lock.withLock {
                let next = (incarnations[displayID] ?? 0) &+ 1
                incarnations[displayID] = next
                return DDCDisplayConnectionToken(displayID: displayID, incarnation: next)
            }
        }

        func isCurrent(_ token: DDCDisplayConnectionToken) -> Bool {
            lock.withLock {
                (incarnations[token.displayID] ?? 0) == token.incarnation
            }
        }
    }

#endif
