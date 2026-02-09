import Foundation

struct DisplayController {
    static func sleepDisplays() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]

        do {
            try task.run()
        } catch {
            print("Failed to sleep displays:", error.localizedDescription)
        }
    }
}
