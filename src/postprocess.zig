// Deterministic transcript cleanup, the last step before a transcript leaves
// the core (src/c_api.zig). Whisper occasionally gets stuck in a loop and
// emits the same word or short phrase many times in a row; real speech almost
// never repeats a unit three times back to back, so such runs collapse to a
// single occurrence. Re-joining the surviving words also normalizes all
// whitespace runs to single spaces. Purely local and rule-based: no model,
// no network, nothing the user said is ever added, only exact repeats and
// excess whitespace are removed.

const std = @import("std");

/// Longest phrase (in words) checked for looping. Whisper loops are short
/// n-grams; longer units essentially never loop and cost more to scan.
const MAX_PHRASE_WORDS = 4;

/// A unit must appear this many times consecutively to count as a loop.
/// Doubles are common real speech ("that that", "very very"); three or more
/// is the model stuck.
const MIN_LOOP_REPEATS = 3;

/// Cleaned copy of `text`: repetition loops collapsed, whitespace normalized.
/// Caller owns the returned slice.
pub fn clean(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| try words.append(allocator, w);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < words.items.len) {
        const phrase_len = loopAt(words.items, i) orelse {
            try appendWord(allocator, &out, words.items[i]);
            i += 1;
            continue;
        };
        for (words.items[i .. i + phrase_len]) |w| {
            try appendWord(allocator, &out, w);
        }
        i += phrase_len * repeatCount(words.items, i, phrase_len);
    }

    return out.toOwnedSlice(allocator);
}

fn appendWord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), word: []const u8) !void {
    if (out.items.len != 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, word);
}

/// If a repetition loop starts at `i`, the phrase length of the shortest
/// looping unit, else null. Shortest-first, so "a a a a" collapses to "a"
/// rather than the two-word unit "a a" swallowing it in pairs.
fn loopAt(words: []const []const u8, i: usize) ?usize {
    var phrase_len: usize = 1;
    while (phrase_len <= MAX_PHRASE_WORDS) : (phrase_len += 1) {
        if (repeatCount(words, i, phrase_len) >= MIN_LOOP_REPEATS) return phrase_len;
    }
    return null;
}

/// How many times the phrase `words[i..i + phrase_len]` appears back to back
/// starting at `i` (at least 1 when it fits, 0 when it does not).
fn repeatCount(words: []const []const u8, i: usize, phrase_len: usize) usize {
    var count: usize = 0;
    while (phraseEql(words, i, i + count * phrase_len, phrase_len)) {
        count += 1;
    }
    return count;
}

/// Whether the `len`-word phrases at `a` and `b` are byte-identical.
fn phraseEql(words: []const []const u8, a: usize, b: usize, len: usize) bool {
    if (b + len > words.len) return false;
    for (0..len) |k| {
        if (!std.mem.eql(u8, words[a + k], words[b + k])) return false;
    }
    return true;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectClean(expected: []const u8, input: []const u8) !void {
    const got = try clean(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "clean: a word repeated three or more times collapses to one" {
    try expectClean("the cat", "the the the cat");
    try expectClean("go", "go go go go go go");
}

test "clean: legitimate doubles are kept" {
    // "that that" and "very very" are real English; only 3+ is a loop.
    try expectClean("he said that that was fine", "he said that that was fine");
    try expectClean("it was very very good", "it was very very good");
}

test "clean: phrase loops collapse to a single occurrence" {
    try expectClean("and I said stop", "and I said and I said and I said stop");
    try expectClean("thank you.", "thank you. thank you. thank you. thank you.");
}

test "clean: shortest looping unit wins" {
    // "a a a a a a" must become "a", not collapse pairwise to "a a".
    try expectClean("a", "a a a a a a");
}

test "clean: differing punctuation breaks a run" {
    // The final "said." is not byte-identical, so this is two occurrences
    // plus a distinct word: below the loop threshold, kept verbatim.
    try expectClean("I said, I said, I said.", "I said, I said, I said.");
}

test "clean: whitespace runs normalize to single spaces" {
    try expectClean("hello world", "  hello \t  world\n");
    try expectClean("one two", "one\n\ntwo");
}

test "clean: clean text passes through unchanged" {
    const sentence = "Ask not what your country can do for you.";
    try expectClean(sentence, sentence);
}

test "clean: empty and whitespace-only come back empty" {
    try expectClean("", "");
    try expectClean("", "   \n\t ");
}
