// libc++ forward-compatibility shim for the Swift link on macOS.
//
// Zig compiles whisper.cpp's C++ against its bundled (newer) libc++ headers,
// which emit calls to std::__1::__hash_memory, a symbol outlined into the
// libc++ dylib in LLVM 19. The final app link is done by swiftc against the
// SYSTEM libc++, and macOS 15's dylib predates the symbol, so source builds
// on macOS 15 (including the macos-15 CI runner) die with an undefined
// symbol.
//
// Providing a definition here is safe: hash values only need in-process
// self-consistency (they seed unordered containers, never persist), and the
// weak attribute lets the real libc++ definition win wherever one exists.
//
// Only compiled on macOS; on Linux the final link is done by Zig against its
// own bundled libc++, which always has the symbol.

#include <cstddef>
#include <cstdint>

namespace std {
inline namespace __1 {

__attribute__((weak)) size_t __hash_memory(const void *ptr, size_t size) noexcept {
    // FNV-1a, 64-bit. Not libc++'s exact algorithm, which is fine: no code
    // outside this process ever sees these hash values.
    const uint8_t *bytes = static_cast<const uint8_t *>(ptr);
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < size; i++) {
        hash ^= bytes[i];
        hash *= 0x100000001b3ULL;
    }
    return static_cast<size_t>(hash);
}

} // namespace __1
} // namespace std
