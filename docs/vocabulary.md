# Parakeet vocabulary

Parakeet dictation reads `vocabulary.json` in Vella's Application Support directory
before each transcription. It applies changes to an already loaded model on the
next request. It never interrupts an utterance or reloads the checkpoint. Missing
files select an empty list; public builds contain no personal vocabulary.

```json
{"words": [], "boost": 4, "entries": [], "variants": []}
```

`words` contains up to 128 alphabetic single words, each at most 64 characters.
`boost` is a finite number from 0 to 8. An empty list or zero boost disables both
biasing and vocabulary formatting. Write the file atomically. A malformed,
oversized or over-capacity update retains the last valid configuration; the helper's
status reports an error without returning the words. Removing the file clears it.
Unloading or replacing the model clears its configuration error.
`VELLA_SUPPORT_DIR` redirects the file along with the worker's other local state
for isolated testing.

Optional `entries` supplies acoustic entry spellings. For example, an entry with
`word: "Zephyr"`, `surface: "se"`, `prefix: "ze"` permits the decoder to start
through `se` and still requires it to emit the remaining `phyr` suffix. Entries
are applied only to configured words; they are never replacements over finished
transcript text. At most 128 entries are accepted. Their surface contains letters
and optional apostrophes; their nonempty prefix must begin the configured word.
`boostStart: false` admits a surface acoustically without giving it a start bonus.
Optional `variants` entries contain `word` and an exact alternate `spelling`,
allowing an observed suffix spelling to complete the same canonical word. They
have the same count and spelling limits. Keep personal entries and variants in
the private file, too.

## Decoding

A bounded SentencePiece prefix automaton operates before the selected token
enters the prediction network. Starts require a word boundary. An unfinished
prefix can continue across a boundary, so split acoustic spellings can complete
one configured word. Mismatches reset the state; blanks retain it, with expiry
more than eight encoder frames after the previous emitted token. Every audio
chunk starts at the root.

Canonical starts of at least two letters receive `boost / 4`. A complete acoustic
entry surface receives `min(boost / 2, 2)` when its start boost is enabled;
partial surface fragments receive no bonus. Continuations within an acoustic
entry prefix receive no bonus unless they are also canonical prefixes. After
entry, continuations receive `boost`; continuations completing words of at least four letters receive twice
that amount. Completed prefixes receive no further continuation bonus. Blank is
never boosted. When blank wins on original logits, only a completion of a word
of at least four letters may override it. Short words cannot override blank or
split an ordinary word during formatting. Duration decisions and symbol guards
are unchanged.

Completed long decoder paths receive canonical spelling and capitalization,
including configured acoustic entry paths. A joined following alphabetic token
gets a word boundary unless the complete joined tail is an ordinary suffix
(`s`, `es`, `ed`, `d`, `ing`, `er`, `ers`, `est`, `ly`, or possessive apostrophe-s).
The check spans token pieces; an explicit SentencePiece boundary still starts a
new word. Token IDs and timestamps are retained. Partial entries and
similar-looking unrelated transcript words are never rewritten.

The optimized TDT decoder gathers its current table row on the GPU inside each
compiled block, without per-token CPU readback. Tables and prefix state are
explicit graph arguments, so live edits do not become stale captured constants.
Empty configurations retain the original fast graph. Stock MLX fallback uses the
same transition and formatting policy on its serial decoding path. Other model
families are unaffected. This ports the bounded vocabulary mechanism shared with
Heimdall; contextual ASR does not apply to Vireo's speech generation or Verdict's
typed decisions.

The table is limited to 1,024 prefix nodes. Word lists still require task-specific
accuracy checks: biasing can change unrelated speech. Helper status exposes count,
boost and validation error, never the private words. Local evaluation recordings,
manifests and personal lists belong outside this repository.
