# Transcription quality

Research + plan for improving accuracy ("janky, doesn't reflect each word").
First, the honest split:

- **Dropped / wrong words** come from the *model* and the *decode* (and, when
  streaming, the *chunker*). Post-processing cannot recover a word that was
  never transcribed.
- **Repeated / garbled / mis-formatted text** is what *post-processing* can fix.

So both are worth doing, but they fix different symptoms.

## What Boo does today

- Decode: greedy for live streaming ticks (latency), beam search
  (`beam_size`/`best_of` 5) for the batch path and the streaming final decode;
  `no_context = true`, `suppress_nst = true`, `no_timestamps = true`
  (`src/whisper.zig`).
- A confidence filter drops a segment when `no_speech_prob > 0.6 && avg_logprob
  < -0.4` (`keepSegment`) — this can discard real quiet/mumbled speech.
- Streaming: the VAD chunker cuts at utterance-end silence and transcribes each
  chunk **independently** (no cross-chunk context), which is safe against
  repetition but weaker at chunk seams (`src/stream.zig`).
- A silence RMS floor gates hallucination on silent tails.

## What others do (research)

| Lever | Finding | Source |
|---|---|---|
| Model | large-v3-turbo is the recommended dictation model; whisper.cpp reaches ~95% with large-v3. Boo's Parakeet is at that tier and faster. | [spokenly](https://spokenly.app/blog/whisper-model-sizes), [weesper](https://weesperneonflow.ai/en/blog/2026-03-31-voxtral-whisper-open-source-speech-models-comparison-2026/) |
| Beam search | `beam_size=5` + `best_of=5`, `temperature=0.0` is the accuracy config; `best_of=5` is ~3-8% more accurate but ~5x slower. whisper.cpp's own default is only `beam_size=1`. | [saytowords](https://www.saytowords.com/blogs/Whisper-Best-Settings/), [whisper.cpp #1035](https://github.com/ggml-org/whisper.cpp/discussions/1035) |
| `condition_on_previous_text` | Improves accuracy, but is the classic repetition-loop vector — the reason Boo sets `no_context=true`. Keep it off, or on only with a repetition guard. | [saytowords](https://www.saytowords.com/blogs/Whisper-Best-Settings/) |
| Streaming chunking | Naive fixed windows split words; the robust pattern is **LocalAgreement** — emit only text confirmed by two consecutive decodes, scroll the buffer to the last confirmed sentence. Boo cuts on silence (better than fixed windows) but doesn't cross-confirm. | [ufal/whisper_streaming](https://github.com/ufal/whisper_streaming), [arXiv 2307.14743](https://arxiv.org/pdf/2307.14743) |
| Audio | 16 kHz mono f32 — Boo already does this. | [snailtext](https://snailtext.app/blog/how-whisper-cpp-works/) |

## Plan, highest impact first

1. **Model** — Parakeet TDT is the single biggest win and is already the
   recommended download + the in-app downloader (task #32). Most of the
   base.en jankiness is the model.
2. **Beam search on the *final* decode.** Done: `transcribe()` takes a `beam`
   flag; streaming ticks stay greedy, the batch path and the streaming
   finalize tail use beam_size/best_of 5. Measured on the 12-clip LibriSpeech
   suite: WER-neutral (8.5% both ways, clean read speech does not stress the
   decoder), jfk final decode 237 to 337 ms, every CI WER/RTF gate still
   green. Kept because the cost lands only where the user already stopped,
   and upstream's reported gains are on harder audio than the suite.
3. **Loosen `keepSegment`.** The `avg_logprob < -0.4` cutoff likely drops real
   low-confidence speech; raise the bar (or require a stronger no_speech signal)
   and re-measure WER on the LibriSpeech suite.
4. **Deterministic post-processing** (after the full transcript, local, no
   network): collapse verbatim repeated words/phrases (residual whisper
   repetition), normalize whitespace and capitalize sentence starts, strip a
   stray leading/trailing filler token. Plus the roadmap's user-vocabulary
   replacements and spoken-punctuation commands. This fixes *formatting and
   repetition*, not drops.
5. **Streaming LocalAgreement** (larger): cross-confirm chunk seams so words are
   not lost or duplicated across pauses. Only if 1-4 don't settle it.

Every decode change is measured with `zig build bench -- --cpu --assert-wer N`
(single clip) and `--suite tests/eval` (12-speaker WER), red-first with a
regression clip, so accuracy is verified rather than hoped.
