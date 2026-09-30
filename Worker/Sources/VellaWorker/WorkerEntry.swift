import VellaWorkerSupport

@main struct WorkerEntry {
    static func main() async {
        switch WorkerMode(executable: CommandLine.arguments[0]) {
        case .dictation: await DictationMain.main()
        case .streaming: StreamingMain.main()
        }
    }
}
