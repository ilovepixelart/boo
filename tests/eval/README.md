# Accuracy evaluation suite

Twelve utterances from the LibriSpeech `test-clean` set, one per speaker,
converted to Boo's input format (16 kHz mono PCM16 WAV). Each `NAME.wav` has
its ground-truth transcript in `NAME.txt`.

Run it:

```sh
zig build bench -- --suite tests/eval --cpu --assert-wer 8
```

CI gates on the aggregate word error rate (total errors over total reference
words, so short clips aren't over-weighted); per-clip rates are printed for
diagnosis. The bundled jfk.wav remains the streaming-gate clip; this suite is
the batch-accuracy breadth check. One clean clip is a smoke test that sits one
substituted word from failure; twelve speakers make the threshold
statistically meaningful.

Measured baselines (aggregate, deterministic across runs):

| Model | WER |
|---|---|
| base.en (CPU) | 7.9% |
| parakeet-tdt-0.6b-v3-q8_0 | 2.8% |

The CI gate is 12%, 1.5x the base.en baseline. Two clips score high on
base.en by design: 7127 has French proper nouns, and 7729 exercises number
formatting ("thirty six" vs "36"; scoring is deliberately strict about
numbers, see src/wer.zig).

LibriSpeech (Panayotov, Chen, Povey, Khudanpur, 2015) is CC BY 4.0:
https://www.openslr.org/12
