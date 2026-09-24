#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${STREAMING_CHECKS_OUT:-$ROOT/.build/streaming-checks}"
mkdir -p "$OUT"
xcrun swiftc "$ROOT/Sources/VellaStreamingWorker/StreamingSession.swift" "$ROOT/QA/StreamingChecks.swift" -o "$OUT/session"
"$OUT/session"
xcrun swiftc "$ROOT/Sources/VellaStreamingWorker/StreamingSession.swift" "$ROOT/QA/StreamingBoundsChecks.swift" -o "$OUT/bounds"
"$OUT/bounds"
xcrun swiftc "$ROOT/Sources/MLXAudioSTT/VoxtralRealtime/VoxtralRealtimeTranscriptText.swift" "$ROOT/QA/StreamingUTF8Checks.swift" -o "$OUT/utf8"
"$OUT/utf8"
xcrun swiftc "$ROOT/Sources/VellaStreamingWorker/Watchdog.swift" "$ROOT/QA/StreamingWatchdogChecks.swift" -o "$OUT/watchdog"
"$OUT/watchdog"
xcrun swiftc "$ROOT/Sources/VellaStreamingWorker/StreamingSession.swift" "$ROOT/QA/StreamingProtocolFixture.swift" -o "$OUT/protocol-fixture"
# Optional reference test, never needed to build or run either native helper.
if [[ -n "${VELLA_REFERENCE_PYTHON:-}" ]]; then
    "$VELLA_REFERENCE_PYTHON" -B "$ROOT/QA/streaming_protocol_parity.py" "$OUT/protocol-fixture"
    # Preserve Main's control flow; replace only its MLX import/runtime with a
    # CPU fake. Neither this executable nor this shim is a production target.
    sed '/^import MLX$/d' "$ROOT/Sources/VellaStreamingWorker/Main.swift" > "$OUT/Main.swift"
    xcrun swiftc "$OUT/Main.swift" "$ROOT/Sources/VellaStreamingWorker/StreamingSession.swift" "$ROOT/Sources/VellaStreamingWorker/Watchdog.swift" "$ROOT/QA/StreamingCPURuntime.swift" -o "$OUT/wire-worker"
    if [[ "${STREAMING_CHECK_IDLE_TIMEOUT:-0}" == 1 ]]; then
        "$VELLA_REFERENCE_PYTHON" -B "$ROOT/QA/streaming_cpu_wire_checks.py" "$OUT/wire-worker" --idle-timeout
    else
        "$VELLA_REFERENCE_PYTHON" -B "$ROOT/QA/streaming_cpu_wire_checks.py" "$OUT/wire-worker"
    fi
fi
