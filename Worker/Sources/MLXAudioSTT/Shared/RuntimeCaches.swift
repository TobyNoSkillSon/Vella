/// Process-owned frontend constants are cheap to rebuild after model retirement.
public enum STTRuntime {
    public static func clearModelIndependentCaches() {
        WhisperAudio.clearFilterCache()
    }
}
