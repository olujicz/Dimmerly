//
//  DDCSessionGate.swift
//  Dimmerly
//

#if !APPSTORE

    import CoreGraphics
    import Foundation
    import Synchronization

    struct DDCSession: Equatable, Sendable {
        let generation: UInt64
    }

    final class DDCSessionGate: Sendable {
        private struct State {
            var generation: UInt64 = 0
            var enabled = false
        }

        private let state = Mutex(State())

        @discardableResult
        func beginEnabledSession() -> DDCSession {
            state.withLock { state in
                state.generation &+= 1
                state.enabled = true
                return DDCSession(generation: state.generation)
            }
        }

        func capture() -> DDCSession? {
            state.withLock { state in
                state.enabled ? DDCSession(generation: state.generation) : nil
            }
        }

        func isCurrent(_ session: DDCSession) -> Bool {
            state.withLock { state in
                state.enabled && session.generation == state.generation
            }
        }

        func invalidate(_ session: DDCSession) {
            state.withLock { state in
                guard state.enabled, session.generation == state.generation else { return }
                state.enabled = false
                state.generation &+= 1
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

    final class DDCDisplayConnectionGate: Sendable {
        private let incarnations = Mutex<[CGDirectDisplayID: UInt64]>([:])

        func current(for displayID: CGDirectDisplayID) -> DDCDisplayConnectionToken {
            incarnations.withLock { incarnations in
                DDCDisplayConnectionToken(
                    displayID: displayID,
                    incarnation: incarnations[displayID] ?? 0
                )
            }
        }

        func advance(for displayID: CGDirectDisplayID) {
            incarnations.withLock { incarnations in
                incarnations[displayID] = (incarnations[displayID] ?? 0) &+ 1
            }
        }

        func isCurrent(_ token: DDCDisplayConnectionToken) -> Bool {
            incarnations.withLock { incarnations in
                (incarnations[token.displayID] ?? 0) == token.incarnation
            }
        }
    }

#endif
