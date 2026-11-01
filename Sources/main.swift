import Foundation
import AppKit

if CLIRunner.shouldRunCLI(arguments: CommandLine.arguments) {
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task {
        exitCode = await CLIRunner.run(arguments: CommandLine.arguments)
        sema.signal()
    }
    sema.wait()
    exit(exitCode)
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = UBitAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
