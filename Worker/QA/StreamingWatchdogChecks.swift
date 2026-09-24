import Foundation
import Darwin
@main struct Check {
    static func main() {
        let watchdog = StreamingWatchdog(output: STDOUT_FILENO)
        watchdog.arm()
        watchdog.identify("12345678-1234-1234-1234-123456789abc")
        // Main thread deliberately blocked like a GPU operation / idle stdin.
        kill(getpid(), SIGTERM)
        sleep(5)
        fatalError("watchdog failed to terminate")
    }
}
