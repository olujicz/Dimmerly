//
//  DDCSessionGate.swift
//  Dimmerly
//

#if !APPSTORE

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

#endif
