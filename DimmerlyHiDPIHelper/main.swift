//
//  main.swift
//  DimmerlyHiDPIHelper
//
//  The one-shot helper the HiDPI settings run as root, after the administrator prompt, for
//  one change to one display override. It takes no input from files, holds no service open
//  and exits when the change is done. Direct download only.
//

#if !APPSTORE

    import Foundation

    exit(HiDPIHelperCommand.run(Array(CommandLine.arguments.dropFirst()), configuration: .system))

#endif
