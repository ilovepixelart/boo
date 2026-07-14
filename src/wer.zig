// Word error rate, the standard ASR accuracy metric, for the benchmark's
// quality gate. WER = word-level edit distance / reference length, so 0.0 is
// a perfect transcript and values above 1.0 are possible for pathological
// output (e.g. an engine stuck in a repetition loop).
//
// Scoring follows the usual ASR normalization: case and punctuation must not
// count as errors, since "Ask not!" and "ask not" are the same dictation.

const std = @import("std");

/// Lowercase and strip punctuation to spaces (apostrophes survive: "don't"
/// is one word). Caller owns the returned buffer.
pub fn normalize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |ch, i| {
        out[i] = if (std.ascii.isAlphanumeric(ch) or ch == '\'')
            std.ascii.toLower(ch)
        else
            ' ';
    }
    return out;
}

fn splitWords(allocator: std.mem.Allocator, normalized: []const u8) ![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, normalized, ' ');
    while (it.next()) |word| try words.append(allocator, word);
    return words.toOwnedSlice(allocator);
}

pub const WerError = error{EmptyReference} || std.mem.Allocator.Error;

/// Word error rate of `hypothesis` against `reference`, after normalization.
pub fn wordErrorRate(
    allocator: std.mem.Allocator,
    hypothesis: []const u8,
    reference: []const u8,
) WerError!f64 {
    const hyp_norm = try normalize(allocator, hypothesis);
    defer allocator.free(hyp_norm);
    const ref_norm = try normalize(allocator, reference);
    defer allocator.free(ref_norm);

    const hyp = try splitWords(allocator, hyp_norm);
    defer allocator.free(hyp);
    const ref = try splitWords(allocator, ref_norm);
    defer allocator.free(ref);

    if (ref.len == 0) return error.EmptyReference;

    // Levenshtein over words, two rolling rows.
    var above = try allocator.alloc(usize, hyp.len + 1);
    defer allocator.free(above);
    var row = try allocator.alloc(usize, hyp.len + 1);
    defer allocator.free(row);

    for (above, 0..) |*cell, j| cell.* = j;
    for (ref, 1..) |ref_word, i| {
        row[0] = i;
        for (hyp, 1..) |hyp_word, j| {
            const substitution = above[j - 1] + @intFromBool(!std.mem.eql(u8, ref_word, hyp_word));
            const deletion = above[j] + 1;
            const insertion = row[j - 1] + 1;
            row[j] = @min(substitution, @min(deletion, insertion));
        }
        std.mem.swap([]usize, &above, &row);
    }

    // The swap leaves the last computed row in `above`.
    const distance = above[hyp.len];
    return @as(f64, @floatFromInt(distance)) / @as(f64, @floatFromInt(ref.len));
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "wordErrorRate: identical text scores zero" {
    const rate = try wordErrorRate(testing.allocator, "ask not what", "ask not what");
    try testing.expectEqual(@as(f64, 0.0), rate);
}

test "wordErrorRate: case and punctuation are not errors" {
    const rate = try wordErrorRate(
        testing.allocator,
        "And so, my fellow Americans! Ask not!",
        "and so my fellow americans ask not",
    );
    try testing.expectEqual(@as(f64, 0.0), rate);
}

test "wordErrorRate: one substitution in four words is 25%" {
    const rate = try wordErrorRate(testing.allocator, "ask not what yours", "ask not what your");
    try testing.expectApproxEqAbs(@as(f64, 0.25), rate, 0.0001);
}

test "wordErrorRate: insertions count, so echoed text is punished" {
    // The failure mode that motivated this gate: prompt carry-over making the
    // engine repeat text that was never spoken.
    const rate = try wordErrorRate(
        testing.allocator,
        "ask what you can do ask what you can do",
        "ask what you can do",
    );
    try testing.expectApproxEqAbs(@as(f64, 1.0), rate, 0.0001);
}

test "wordErrorRate: empty hypothesis is total error" {
    const rate = try wordErrorRate(testing.allocator, "", "ask not");
    try testing.expectApproxEqAbs(@as(f64, 1.0), rate, 0.0001);
}

test "wordErrorRate: apostrophes stay inside words" {
    const rate = try wordErrorRate(testing.allocator, "don't stop", "don't stop");
    try testing.expectEqual(@as(f64, 0.0), rate);
}

test "wordErrorRate: empty reference is an error, not a division by zero" {
    try testing.expectError(error.EmptyReference, wordErrorRate(testing.allocator, "words", "..."));
}
