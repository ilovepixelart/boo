// Native-runner tests for the Windows download verify/rename logic. Includes
// the source under test so its statics are reachable. The WinHTTP transfer
// itself is exercised end to end by onboarding; what must never regress
// silently is the digest check and the .part promotion.

#include "download.c"

#include <stdio.h>

static int failures = 0;

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// Hash `data` with CNG exactly as the downloader does.
static bool hash_bytes(const void *data, size_t len, BCRYPT_HASH_HANDLE *out_hash,
                       BCRYPT_ALG_HANDLE *out_alg) {
    if (BCryptOpenAlgorithmProvider(out_alg, BCRYPT_SHA256_ALGORITHM, NULL, 0) != 0)
        return false;
    if (BCryptCreateHash(*out_alg, out_hash, NULL, 0, NULL, 0, 0) != 0) return false;
    return BCryptHashData(*out_hash, (PUCHAR)data, (ULONG)len, 0) == 0;
}

int main(void) {
    printf("download_test:\n");

    // SHA-256("abc"), the FIPS 180 test vector; case-insensitive match.
    static const char abc_sha[] =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    check(hash_bytes("abc", 3, &hash, &alg), "CNG hashing available");
    check(digest_matches(hash, abc_sha), "digest matches the FIPS vector");
    BCryptCloseAlgorithmProvider(alg, 0);

    BCRYPT_ALG_HANDLE alg2 = NULL;
    BCRYPT_HASH_HANDLE hash2 = NULL;
    hash_bytes("abc", 3, &hash2, &alg2);
    check(!digest_matches(hash2, "00ff00ff"), "wrong digest is rejected");
    BCryptCloseAlgorithmProvider(alg2, 0);

    // finish_part: the .part only takes the real name when the digest holds.
    WCHAR tmp[MAX_PATH];
    WCHAR part[MAX_PATH];
    WCHAR final_path[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"TEMP", tmp, MAX_PATH);
    if (n > 0 && n < MAX_PATH &&
        swprintf(part, MAX_PATH, L"%ls\\boo-dl-test.part", tmp) >= 0 &&
        swprintf(final_path, MAX_PATH, L"%ls\\boo-dl-test.bin", tmp) >= 0) {
        FILE *f = _wfopen(part, L"wb");
        if (f) {
            fwrite("abc", 1, 3, f);
            fclose(f);
        }
        _wremove(final_path);

        const BooModelInfo fake = {.filename = "boo-dl-test.bin",
                                   .url = "https://example.invalid/x",
                                   .sha256 = abc_sha,
                                   .label = "t",
                                   .note = "t",
                                   .size = 3};
        const DownloadJob job = {.notify = NULL, .model = &fake};

        BCRYPT_ALG_HANDLE alg3 = NULL;
        BCRYPT_HASH_HANDLE hash3 = NULL;
        hash_bytes("abc", 3, &hash3, &alg3);
        const char *why = NULL;
        check(finish_part(hash3, &job, part, final_path, &why),
              "matching digest promotes the .part");
        check(GetFileAttributesW(final_path) != INVALID_FILE_ATTRIBUTES,
              "the final file exists");
        check(GetFileAttributesW(part) == INVALID_FILE_ATTRIBUTES,
              "the .part is gone after promotion");
        BCryptCloseAlgorithmProvider(alg3, 0);

        // Mismatch: nothing is promoted and the reason names the checksum.
        f = _wfopen(part, L"wb");
        if (f) {
            fwrite("xyz", 1, 3, f);
            fclose(f);
        }
        BCRYPT_ALG_HANDLE alg4 = NULL;
        BCRYPT_HASH_HANDLE hash4 = NULL;
        hash_bytes("xyz", 3, &hash4, &alg4);
        why = NULL;
        check(!finish_part(hash4, &job, part, final_path, &why),
              "wrong digest refuses promotion");
        check(why && strstr(why, "checksum") != NULL, "the reason names the checksum");
        BCryptCloseAlgorithmProvider(alg4, 0);
        _wremove(part);
        _wremove(final_path);
    } else {
        check(false, "TEMP fixture paths");
    }

    printf("download_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
