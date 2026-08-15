//! Conformance: Die beiden Seiten des JSON-Protokollvertrags muessen
//! binaergleich sein.
//!
//! Die Fassade aus dem gepinnten SDK-Paket unter r4os/json.zig und der lokale
//! Protokollkern unter src/json_core.zig deklarieren dieselben
//! Strukturen getrennt voneinander - sie muessen es, weil die Fassade den
//! Parser NICHT einbetten darf. Genau deshalb kann das auseinanderlaufen,
//! und genau deshalb wird es hier gegeneinander gehalten statt gegen
//! selbstgeschriebene Zahlen.

const std = @import("std");
const core = @import("core");
const facade = @import("facade");

fn expectSameLayout(comptime A: type, comptime B: type) !void {
    try std.testing.expectEqual(@sizeOf(A), @sizeOf(B));
    try std.testing.expectEqual(@alignOf(A), @alignOf(B));
    const a_fields = @typeInfo(A).@"struct".fields;
    const b_fields = @typeInfo(B).@"struct".fields;
    try std.testing.expectEqual(a_fields.len, b_fields.len);
    inline for (a_fields, b_fields) |fa, fb| {
        try std.testing.expectEqualStrings(fa.name, fb.name);
        try std.testing.expectEqual(@offsetOf(A, fa.name), @offsetOf(B, fb.name));
        try std.testing.expectEqual(@sizeOf(fa.type), @sizeOf(fb.type));
    }
}

test "cursor layout is identical on both sides of the protocol" {
    try expectSameLayout(core.Cursor, facade.Cursor);
}

test "token numbers are identical on both sides" {
    try std.testing.expectEqual(core.tok_end, @intFromEnum(facade.Token.end));
    try std.testing.expectEqual(core.tok_object_begin, @intFromEnum(facade.Token.object_begin));
    try std.testing.expectEqual(core.tok_object_end, @intFromEnum(facade.Token.object_end));
    try std.testing.expectEqual(core.tok_array_begin, @intFromEnum(facade.Token.array_begin));
    try std.testing.expectEqual(core.tok_array_end, @intFromEnum(facade.Token.array_end));
    try std.testing.expectEqual(core.tok_key, @intFromEnum(facade.Token.key));
    try std.testing.expectEqual(core.tok_string, @intFromEnum(facade.Token.string));
    try std.testing.expectEqual(core.tok_number, @intFromEnum(facade.Token.number));
    try std.testing.expectEqual(core.tok_true, @intFromEnum(facade.Token.true_value));
    try std.testing.expectEqual(core.tok_false, @intFromEnum(facade.Token.false_value));
    try std.testing.expectEqual(core.tok_null, @intFromEnum(facade.Token.null_value));
    try std.testing.expectEqual(core.tok_none, @intFromEnum(facade.Token.none));
}

test "every protocol status code has a named error in the facade" {
    // Der Kern darf keinen Code melden, den die Fassade nicht benennen kann -
    // sonst faellt ein Fehler beim Aufrufer als generisches Unavailable an.
    const codes = [_]i32{
        core.err_bad_request,
        core.err_bad_document,
        core.err_unknown_op,
        core.err_output_too_small,
        core.err_depth_exceeded,
        core.err_not_found,
        core.err_bad_path,
        core.err_wrong_token,
    };
    for (codes) |code| {
        const mapped = facade.mapStatus(code) orelse return error.TestUnexpectedResult;
        try std.testing.expect(mapped != facade.Error.Unavailable);
    }
    // Gegenprobe: Erfolg bleibt Erfolg, und ein unbekannter Code faellt
    // sichtbar auf Unavailable statt still durchzugehen.
    try std.testing.expect(facade.mapStatus(core.err_ok) == null);
    try std.testing.expect(facade.mapStatus(-12345).? == facade.Error.Unavailable);
}
