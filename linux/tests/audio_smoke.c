// Drives Boo's C API directly against a live PipeWire graph.
// Verifies the Linux audio backend actually captures, and that whisper
// transcribes what it captured. Nothing here touches the GUI.
#include "boo.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <model.bin> <record_seconds>\n", argv[0]);
        return 64;
    }
    const int seconds = atoi(argv[2]);

    printf("[smoke] boo_init(%s)\n", argv[1]);
    BooContext *ctx = boo_init(argv[1]);
    if (!ctx) {
        fprintf(stderr, "[smoke] FAIL: boo_init returned NULL\n");
        return 1;
    }

    printf("[smoke] warm_up + start_recording\n");
    boo_warm_up(ctx);
    boo_start_recording(ctx);

    if (!boo_is_recording(ctx)) {
        fprintf(stderr, "[smoke] FAIL: not recording after start\n");
        return 1;
    }

    // The caller plays audio into the virtual mic during this window.
    for (int i = 0; i < seconds; i++) {
        sleep(1);
        printf("[smoke]   t=%ds samples=%d peak_rms=%.4f\n", i + 1,
               boo_get_audio_samples(ctx), boo_get_peak_rms(ctx));
    }

    boo_stop_recording(ctx);
    const int samples = boo_get_audio_samples(ctx);
    printf("[smoke] stopped: %d samples (%.2fs @16kHz)\n", samples,
           samples / 16000.0);

    if (samples <= 0) {
        fprintf(stderr, "[smoke] FAIL: PipeWire captured no audio at all\n");
        return 2;
    }

    printf("[smoke] transcribing...\n");
    const char *text = boo_transcribe(ctx);
    printf("[smoke] TRANSCRIPT: %s\n", text ? text : "(null)");

    int rc = 0;
    if (!text || !*text) {
        fprintf(stderr, "[smoke] FAIL: captured audio but transcript empty\n");
        rc = 3;
    } else {
        printf("[smoke] PASS: captured %d samples and transcribed them\n", samples);
    }

    boo_deinit(ctx);
    return rc;
}
