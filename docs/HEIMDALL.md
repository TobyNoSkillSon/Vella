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
Triggers are judged per word, whatever the line's share: only words whose middle lies outside dictation can name
Heimdall, say "send it", fall in the follow-up window, stop it or match a spoken command, so a few dictated words in a
spoken line never wake it and words said after the stop wake as usual. In such a mixed line the decider and the agent
see the dictated run marked `[dictated to Vella: …]`; the archive keeps the words as said.

## Channel 2: the transcription socket

Heimdall announces itself with `dev.heimdall.asr` (object `"dev.heimdall"`) when its listen model is ready and when
it stops, and in reply to Vella's `dev.vella.asr.query`. userInfo: `v` 1, `state` (`ready` | `gone`), `socket`
(absolute path, mode 0600), `model` (`parakeet-v3-ultra`), `pid`, `sent`, `app` (the announcing edition's app ID).

The socket has one fixed folder per edition, chosen by the build's edition, never by the movable data folder, so the
two editions never share app data or answer for each other:

| edition | app ID | socket |
|---|---|---|
| personal | `dev.heimdall.app` | `~/Library/Application Support/Heimdall/asr.sock` (the original profile folder; after a home move it is the link to the new place) |
| public | `com.tobynoskillson.heimdall` | `~/Library/Application Support/com.tobynoskillson.heimdall/asr.sock` (beside `home.json`) |

A lab or test run on its own `--data` keeps the socket in that folder. Path limit: macOS socket paths are under 104
bytes, which the public path meets for user names up to 31 characters; a longer name makes the socket refuse to start
(logged, retried every 30 s) and Vella keeps its own model.

Vella trusts a `ready` only when its socket is one of those two paths, `app` is the matching edition, the socket is
owned by the user with mode 0600 and not a link, and the connected peer runs as the user with the announced pid. With
both editions ready, Vella borrows from the personal edition and names the one it uses in its status.

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

**Vella's choice and fallback:** Vella's Models table has a "Parakeet v3 Ultra · from Heimdall" row, a normal
selectable row. It is the default for a user who never chose, and a selection of Vella's own Ultra made before this
integration moves to it when Heimdall is present; any explicit choice afterwards stands. While that row is chosen,
Vella sends one request per finished dictation and keeps its own Ultra unloaded and undownloaded. Any connect failure,
`ok:false` or no reply within 5 s plus a tenth of the audio length falls back, for that dictation, to Vella's own Ultra
if it is already downloaded (otherwise its usual Get offer; never a silent download), and marks Heimdall unavailable
until its next `ready`. With Heimdall absent the row is greyed; its link to Heimdall's public page opens nothing until
that URL is configured.

**Vella side (as built):** one request per finished dictation (the whole recording). Files sent to Vella's API for Parakeet v3 Ultra use the socket too, one request per segment of up to 25 s, but only when no vocabulary applies (Heimdall's socket takes none); a `busy` reply is waited for briefly, and any other failure sends that segment to Vella's own copy without marking Heimdall unavailable, so dictation keeps borrowing. The "Parakeet v3 Ultra · from Heimdall" row borrows when it is the dictation choice: chosen explicitly, or the default for an install with no selection yet. A selection stored before this build is kept as the user's choice. Trust per edition as above; the signing identity is read with `SecCodeCopyGuestWithAttributes` for the announcing pid.
