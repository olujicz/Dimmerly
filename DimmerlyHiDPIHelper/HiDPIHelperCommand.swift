//
//  HiDPIHelperCommand.swift
//  DimmerlyHiDPIHelper
//
//  The helper's command line: parsing, strict validation, and the exit codes the app reads.
//  Built into the helper tool and into the app target for the tests.
//

#if !APPSTORE

    import Darwin
    import Foundation

    nonisolated enum HiDPIHelperCommand {
        enum Request: Equatable {
            case install(vendorID: UInt32, productID: UInt32, contents: Data)
            case remove(vendorID: UInt32, productID: UInt32, digest: String)
            case recover(vendorID: UInt32, productID: UInt32)

            /// The helper's command-line arguments for this request.
            var arguments: [String] {
                switch self {
                case let .install(vendor, product, contents):
                    ["install", String(vendor), String(product), contents.base64EncodedString()]
                case let .remove(vendor, product, digest):
                    ["remove", String(vendor), String(product), digest]
                case let .recover(vendor, product):
                    ["recover", String(vendor), String(product)]
                }
            }
        }

        /// Exit codes the app understands.
        enum ExitCode {
            static let done: Int32 = 0
            static let refused: Int32 = 1
            static let invalidInput: Int32 = 2
            static let held: Int32 = 3
            static let unsafe: Int32 = 4
            static let failed: Int32 = 5
        }

        /// What the helper prints, on stderr, ahead of the path of a held original.
        static let heldMarker = "DIMMERLY-HELD"

        /// `install <vendor> <product> <base64 plist>`, `remove <vendor> <product> <sha256 hex>`
        /// or `recover <vendor> <product>`. Numbers are plain decimal; nothing else is accepted.
        static func parse(_ arguments: [String]) -> Request? {
            guard arguments.count >= 3, let vendor = identifier(arguments[1]), let product = identifier(arguments[2])
            else {
                return nil
            }
            switch (arguments[0], arguments.count) {
            case ("install", 4):
                guard let contents = Data(base64Encoded: arguments[3]), !contents.isEmpty else { return nil }
                return .install(vendorID: vendor, productID: product, contents: contents)
            case ("remove", 4):
                guard isDigest(arguments[3]) else { return nil }
                return .remove(vendorID: vendor, productID: product, digest: arguments[3])
            case ("recover", 3):
                return .recover(vendorID: vendor, productID: product)
            default:
                return nil
            }
        }

        /// A display vendor or product number: decimal digits only, not zero and not all ones.
        private static func identifier(_ text: String) -> UInt32? {
            guard !text.isEmpty, text.count <= 10, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = UInt32(text), value != 0, value != UInt32.max
            else {
                return nil
            }
            return value
        }

        private static func isDigest(_ text: String) -> Bool {
            text.count == 64 && text.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
        }

        static func run(
            _ arguments: [String],
            configuration: HiDPITransaction.Configuration,
            standardError: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        ) -> Int32 {
            guard let request = parse(arguments) else {
                standardError("Dimmerly: invalid arguments")
                return ExitCode.invalidInput
            }
            do {
                let outcome: HiDPITransaction.Outcome = switch request {
                case let .install(vendor, product, contents):
                    try HiDPITransaction.install(
                        model: .init(vendorID: vendor, productID: product),
                        contents: contents,
                        configuration: configuration
                    )
                case let .remove(vendor, product, digest):
                    try HiDPITransaction.remove(
                        model: .init(vendorID: vendor, productID: product),
                        expectedDigest: digest,
                        configuration: configuration
                    )
                case let .recover(vendor, product):
                    try HiDPITransaction.recover(
                        model: .init(vendorID: vendor, productID: product), configuration: configuration
                    )
                }
                switch outcome {
                case .done:
                    return ExitCode.done
                case let .refused(reason):
                    standardError("Dimmerly: \(reason)")
                    return ExitCode.refused
                case let .held(path):
                    standardError("\(heldMarker) \(path)")
                    return ExitCode.held
                }
            } catch let failure as HiDPITransaction.Failure {
                switch failure {
                case .notRoot:
                    standardError("Dimmerly: this helper must run as root")
                    return ExitCode.unsafe
                case .missing:
                    standardError("Dimmerly: a folder that was expected is missing")
                    return ExitCode.refused
                case let .invalidInput(message):
                    standardError("Dimmerly: \(message)")
                    return ExitCode.invalidInput
                case let .unsafe(message), let .unsupported(message):
                    standardError("Dimmerly: \(message)")
                    return ExitCode.unsafe
                case let .io(message):
                    standardError("Dimmerly: \(message)")
                    return ExitCode.failed
                }
            } catch {
                standardError("Dimmerly: the change didn't complete")
                return ExitCode.failed
            }
        }
    }

#endif
