import VellaWorkerSupport
import Darwin

@main struct WorkerEntry {
    /// The parent also enforces 45 s, but may itself crash or be retired. The child must not survive it forever.
    static func armSelfTestDeadline(
        arguments: [String],
        arm: (UInt32) -> Void = { seconds in
            signal(SIGALRM, SIG_DFL); alarm(seconds)
        }
    ) {
        if arguments.dropFirst().first == "fast-selftest" { arm(45) }
    }
    static func main() async {
        armSelfTestDeadline(arguments: CommandLine.arguments)
        switch WorkerMode(executable: CommandLine.arguments[0]) {
        case .dictation: await DictationMain.main()
        case .streaming: StreamingMain.main()
        }
    }
}
