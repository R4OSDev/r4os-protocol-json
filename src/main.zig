//! JSON.R4P - Rolle format.json, Kategorie data.
//!
//! Duenner R4P-Rahmen ueber json_core. Hier steht nur die Uebersetzung
//! zwischen ProtocolBuffer und dem Kern; alles Fachliche liegt in
//! json_core.zig und ist dadurch auf dem Host inline testbar.
//!
//! protocolDispatch ist zustandslos - Rolle, Opcode, rein, raus. Ein Cursor
//! lebt aber ueber mehrere Aufrufe, deshalb besitzt ihn der AUFRUFER und gibt
//! ihn in der Request mit. Das Modul haelt keine Sitzungen, keine
//! Besitzverhaeltnisse und keine Lebensdauern.

const r4os = @import("r4os");
const core = @import("json_core.zig");

pub const Cursor = core.Cursor;

// Opcodes. Append-only: bestehende Nummern werden nie neu belegt.
pub const op_open: u32 = 1;
pub const op_next: u32 = 2;
pub const op_select: u32 = 3;
pub const op_value: u32 = 4;
pub const op_enter: u32 = 5;
pub const op_next_element: u32 = 6;
pub const op_set: u32 = 7;
pub const op_remove: u32 = 8;
pub const op_insert: u32 = 9;

/// Worauf in_buffer.data zeigt. Nicht jede Operation nutzt jedes Feld.
pub const Request = extern struct {
    cursor: ?*core.Cursor = null,
    doc: ?[*]const u8 = null,
    doc_len: u32 = 0,
    path: ?[*]const u8 = null,
    path_len: u32 = 0,
    value: ?[*]const u8 = null,
    value_len: u32 = 0,
};

comptime {
    if (!@import("builtin").is_test) asm (r4os.technical2.protocolEntriesAsm("json_protocol_init", "json_protocol_shutdown", "json_protocol_query", "json_protocol_dispatch"));
}

export fn json_protocol_init(api: *const r4os.r4dev.ProtocolApi2) callconv(.c) i32 {
    var ctx = r4os.r4dev.ProtocolContext2.init(api);
    if (!ctx.requires(.{ "register_role", "set_status" })) return r4os.abi.err_no_fn;
    const registered = ctx.registerRole("format.json", .data, 0);
    if (registered != 0) return registered;
    const result = ctx.setStatus(.active, "json protocol active");
    return result;
}

export fn json_protocol_shutdown() callconv(.c) i32 {
    return 0;
}

export fn json_protocol_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("json reader and editor ready"),
    };
    return 0;
}

export fn json_protocol_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    const request = requestOf(in_buffer) orelse return core.err_bad_request;
    const cursor = request.cursor orelse return core.err_bad_request;
    if (@intFromPtr(cursor) % @alignOf(core.Cursor) != 0 or @addWithOverflow(@intFromPtr(cursor), @sizeOf(core.Cursor))[1] != 0) return core.err_bad_request;
    return switch (op) {
        op_open => openDocument(cursor, request),
        op_next => core.next(cursor),
        op_select => selectPath(cursor, request),
        op_value => copyValue(cursor, out_buffer),
        op_enter => core.enter(cursor),
        op_next_element => core.nextElement(cursor),
        op_set => edit(cursor, request, out_buffer, .set),
        op_remove => edit(cursor, request, out_buffer, .remove),
        op_insert => edit(cursor, request, out_buffer, .insert),
        else => core.err_unknown_op,
    };
}

const EditKind = enum { set, remove, insert };

/// Die drei Aenderungen unterscheiden sich nur in der Kernfunktion; Puffer-
/// und Groessenbehandlung sind identisch. out_buffer.len traegt danach IMMER
/// die benoetigte Groesse - auch im Fehlerfall, damit der Aufrufer weiss, wie
/// gross er wiederholen muss.
fn edit(cursor: *core.Cursor, request: *const Request, out_buffer: *r4os.abi.ProtocolBuffer, kind: EditKind) i32 {
    const path = sliceOf(request.path, request.path_len) orelse return core.err_bad_request;
    const out = outputBytes(out_buffer) orelse return core.err_bad_request;
    var written: u32 = 0;
    const rc = switch (kind) {
        .set => blk: {
            const value = sliceOf(request.value, request.value_len) orelse break :blk core.err_bad_request;
            break :blk core.set(cursor, path, value, out, &written);
        },
        .remove => core.remove(cursor, path, out, &written),
        .insert => blk: {
            const value = sliceOf(request.value, request.value_len) orelse break :blk core.err_bad_request;
            break :blk core.insert(cursor, path, value, out, &written);
        },
    };
    out_buffer.len = written;
    return rc;
}

fn openDocument(cursor: *core.Cursor, request: *const Request) i32 {
    const doc = sliceOf(request.doc, request.doc_len) orelse return core.err_bad_request;
    return core.open(cursor, doc);
}

fn selectPath(cursor: *core.Cursor, request: *const Request) i32 {
    const path = sliceOf(request.path, request.path_len) orelse return core.err_bad_request;
    return core.select(cursor, path);
}

/// Passt der Wert nicht, wird die BENOETIGTE Groesse gemeldet und der
/// Aufrufer wiederholt mit groesserem Puffer. Keine stille Allokation.
fn copyValue(cursor: *core.Cursor, out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    const bytes = cursor.tokenBytes() orelse return core.err_bad_document;
    const out = outputBytes(out_buffer) orelse return core.err_bad_request;
    out_buffer.len = @intCast(bytes.len);
    if (bytes.len > out.len) return core.err_output_too_small;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) out[i] = bytes[i];
    return core.err_ok;
}

fn sliceOf(ptr: ?[*]const u8, len: u32) ?[]const u8 {
    const base = ptr orelse return null;
    return (r4os.binary_cursor.Span{ .address = @intFromPtr(base), .length = len }).bytes() catch null;
}

fn requestOf(buffer: *const r4os.abi.ProtocolBuffer) ?*const Request {
    const native = r4os.native_protocol_view;
    return (native.Input(Request).init(buffer, native.Policy.record(Request, .input, .prefix)) catch return null).value;
}

fn outputBytes(buffer: *const r4os.abi.ProtocolBuffer) ?[]u8 {
    if (buffer.data == null) return null;
    if (buffer.reserved != 0 or buffer.flags != 0 or buffer.len > buffer.capacity) return null;
    if (@addWithOverflow(@intFromPtr(buffer.data.?), buffer.capacity)[1] != 0) return null;
    if (buffer.capacity != 0) _ = r4os.native_protocol_view.admit(buffer, r4os.native_protocol_view.Policy.record(u8, .output, .prefix), .output) catch return null;
    const ptr: [*]u8 = @ptrCast(buffer.data.?);
    return ptr[0..@intCast(buffer.capacity)];
}

fn note(comptime text: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    @memcpy(out[0..text.len], text);
    return out;
}
