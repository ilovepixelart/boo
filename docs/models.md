# Choosing a model

Any GGML model from
[ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) works,
33 of them, plus NVIDIA Parakeet from
[ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF). Point
Boo at one by dropping it in `~/.boo/models/` (`%USERPROFILE%\.boo\models` on
Windows), or set `BOO_MODEL=/path/to/model.bin` (Linux and Windows). The full
per-OS search paths are in each install guide.

The ones worth knowing about:

| Model | Size | Notes |
|---|---|---|
| `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | 669 MB | **The best pick.** Near large-v3 accuracy at base.en speed; 25 European languages, auto-detected. |
| `ggml-base.en.bin` | 148 MB | **The default.** English-only, fast, good enough for dictation. |
| `ggml-base.en-q5_1.bin` | 60 MB | Same model, quantized. Nearly as accurate, less than half the size. |
| `ggml-tiny.en-q5_1.bin` | 32 MB | Fastest, noticeably worse. For weak hardware. |
| `ggml-small.en.bin` | 488 MB | Clearly better than base; still quick on Apple Silicon. |
| `ggml-large-v3-turbo-q5_0.bin` | 574 MB | **Best whisper accuracy per byte.** Multilingual, far faster than large-v3. |

With several models installed, Boo picks the most capable one it recognizes:
`parakeet`, then `large-v3-turbo` (either flavor), then `small.en`, then
`base.en`, before falling back alphabetically. On an Apple Silicon GPU,
Parakeet transcribes at ~120x realtime (11s of audio in under 100ms); turbo
runs at ~20x.

You rarely need the shell for any of this: first run with no model offers a
download dialog, and **Settings has a model switcher**, one dropdown of
everything on disk plus the curated models not yet downloaded (picking one
downloads it with progress, verifies its pinned SHA-256, and swaps to it in
place). An explicit choice there persists and beats the capability ranking on
later launches. Partial files from an interrupted manual download are detected
by size and skipped, and offered for re-download instead.

The `.en` models are English-only. Everything else is multilingual, but see
[Non-English dictation](#non-english-dictation), or they'll silently produce
English.

## Streaming transcription (automatic)

With a Silero VAD model beside your speech model, Boo transcribes each phrase
*while you're still talking*, at the natural pauses. Committed text appears
live in the overlay, and stopping only waits for the final phrase instead of
the whole recording, so long dictations land near-instantly.

**Every frontend fetches this model itself** on first run (it is under 1 MB,
verified against a SHA-256 pinned in the binary), so streaming just starts
working; until it lands, Boo transcribes the whole recording after you stop.
`BOO_VAD_MODEL=/path/to/model.bin` overrides the search, matching
`BOO_MODEL`.

## Non-English dictation

Boo transcribes in **English by default**, because the recommended model is
English-only. With a multilingual model, that default would silently
*translate* your speech into English rather than transcribe it. Override it:

```sh
BOO_LANG=de   boo-app      # German
BOO_LANG=auto boo-app      # let whisper detect the language
```

`BOO_LANG` has no effect on `.en` models: they can only ever produce English.
It also has no effect on Parakeet models, which auto-detect the language on
their own.
