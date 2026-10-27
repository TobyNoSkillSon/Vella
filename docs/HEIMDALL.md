# Vella integration

Vella (Toby's dictation app, `Projects/Vella`) and Heimdall talk over two local channels. Both are optional: each app
works alone, and nothing is sent anywhere off the Mac.

1. **Dictation state and keybind** (Vella → Heimdall): macOS distributed notifications. While Vella records,
   Heimdall keeps capturing and archiving, but nothing heard can wake the agent; those lines reach the agent's
   context marked as dictated to Vella, and the island shows Vella's mark.
2. **Shared transcription model** (Vella → Heimdall → Vella): a Unix socket. When both apps run Parakeet Ultra,
   Vella sends a finished dictation's audio to the model Heimdall already holds instead of loading its own copy.

## Why notifications, not a key tap

Vella owns the hotkey (Carbon `RegisterEventHotKey`, or an event tap for modifier-only and mouse triggers) and knows
the real state: whether a press actually started recording (no model, no microphone permission, hold-to-talk,
tap-or-hold, a menu click, `vella` CLI). A listen-only tap in Heimdall would see presses, not state, would need Input
Monitoring permission, and would drift whenever a press does not toggle. Vella's own announcement carries the state
and the current keybind, so a keybind change in Vella reaches Heimdall with no second setting to keep in sync.

## Channel 1: `dev.vella.dictation.state`

Posted by Vella on `NSDistributedNotificationCenter.default` with object `"dev.vella.dictation"` and
`deliverImmediately: true`. userInfo (property-list types only):

| key | type | meaning |
|---|---|---|
| `v` | Int | protocol version, 1 |
| `state` | String | `"on"` while Vella records (from the press that starts preparing until recording stops), else `"off"` |
| `reason` | String | `start`, `stop`, `heartbeat`, `hello` (launch, keybind change, or a reply to Heimdall's query), `quit` |
| `session` | String | UUID of the recording session (empty when off and none ran) |
| `pid` | Int | Vella's process id |
| `sent` | Double | Unix seconds when posted |
| `mode` | String | `dictation` or `streaming` |
| `shortcut` | String | the active binding as JSON, exactly Vella's `shortcuts.json` form |
| `shortcutLabel` | String | display form, e.g. `⌃⌘N · Toggle` |

While `on`, Vella posts a `heartbeat` every 15 s. Vella posts `quit` (state off) from `applicationWillTerminate`.

Heimdall posts `dev.heimdall.vella.query` (object `"dev.heimdall"`, no userInfo) when it starts; Vella answers with
a `hello`.

**Heimdall's safety timeout:** dictation counts as on only while a heartbeat arrived within the last 45 s and
Vella's pid is alive. A missed `stop` (crash, lost notification) therefore restores normal waking within 45 s;
a dictation that genuinely runs longer keeps its heartbeats and stays muted.

**Which utterances are dictated:** Heimdall stamps `start`/`stop` on its host clock at receipt (less the posting
delay, clamped to 0–2 s). An utterance whose audio overlaps dictation intervals for at least half its length is
dictated: archived as usual, never sent early, never a spoken command, never decided on, never a wake; it enters
the agent's context as `[dictated to Vella] …`.

## Channel 2: the transcription socket

Heimdall announces itself with `dev.heimdall.asr` (object `"dev.heimdall"`) when its listen model is ready and when
it stops, and in reply to Vella's `dev.vella.asr.query`. userInfo: `v` 1, `state` (`ready` | `gone`), `socket`
(absolute path, `~/Library/Application Support/Heimdall/asr.sock`, mode 0600), `model` (`parakeet-v3-ultra`),
`pid`, `sent`.

One connection per request. Request: one JSON line, then raw audio:

```
{"v":1,"op":"transcribe","model":"parakeet-v3-ultra","rate":16000,"samples":N,"format":"f32le"}\n
<N × 4 bytes, mono 16 kHz little-endian float32>
```

`{"v":1,"op":"status"}\n` asks for readiness without audio.

Response: one JSON line, then the connection closes:

```
{"v":1,"ok":true,"text":"…","queue_ms":3,"decode_ms":120,"audio_ms":8400}
{"v":1,"ok":false,"error":"busy|unavailable|too_long|bad_request|model_mismatch"}
```

Limits: at most 10 minutes of audio per request, at most one request decoding and one waiting; more is `busy`.

**Starvation:** Heimdall's listen worker owns the model on one thread. A Vella request is cut into the engine's
15 s windows and decoded one window per scheduling turn, round-robin with the live sources, so a long dictation
never holds Heimdall's microphone queue (1.6 s per source) long enough to overflow, and live listening never holds a
dictation for more than one live step.

**Vella's fallback:** Vella borrows only when its selected dictation model is Parakeet v3 Ultra and Heimdall has
announced `ready`. Any connect failure, `ok:false` or no reply within 5 s plus a tenth of the audio length falls back to Vella's own model for that
dictation (loading it if needed) and marks Heimdall unavailable until its next `ready`. While borrowing, Vella keeps
its own Parakeet Ultra unloaded and does not need it downloaded.
