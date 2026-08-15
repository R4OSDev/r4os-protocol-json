//! Reiner JSON-Kern: Tokenizer mit Bytegrenzen, Pfadselektor und Iterator.
//!
//! Bewusst OHNE r4os-Abhaengigkeit. Der R4P-Rahmen in main.zig uebersetzt nur
//! zwischen ProtocolBuffer und diesen Funktionen; alles Fachliche steht hier.
//! Dadurch laeuft derselbe Produktivcode in Inline-Tests auf dem Host, ohne
//! QEMU und ohne Zielsystem.
//!
//! Kein Heap, kein Baum, keine Rekursion. Der Aufrufer besitzt den Cursor
//! samt Tiefenfeld - dessen Groesse IST die Verschachtelungsgrenze.

// ------------------------------------------------------------- Tokenarten

/// Frisch geoeffneter Cursor: es wurde noch nichts gelesen. Bewusst NICHT
/// tok_end - sonst kann ein Aufrufer "noch nicht angefangen" nicht von "am
/// Dokumentende" unterscheiden und laeuft mit einer naheliegenden
/// Schleifenbedingung nie los.
pub const tok_none: u32 = 255;

pub const tok_end: u32 = 0;
pub const tok_object_begin: u32 = 1;
pub const tok_object_end: u32 = 2;
pub const tok_array_begin: u32 = 3;
pub const tok_array_end: u32 = 4;
pub const tok_key: u32 = 5;
pub const tok_string: u32 = 6;
pub const tok_number: u32 = 7;
pub const tok_true: u32 = 8;
pub const tok_false: u32 = 9;
pub const tok_null: u32 = 10;

// ------------------------------------------------------------ Fehlercodes

pub const err_ok: i32 = 0;
pub const err_bad_request: i32 = -2;
pub const err_bad_document: i32 = -3;
pub const err_unknown_op: i32 = -4;
pub const err_output_too_small: i32 = -5;
pub const err_depth_exceeded: i32 = -6;
pub const err_not_found: i32 = -7;
pub const err_bad_path: i32 = -8;
pub const err_wrong_token: i32 = -9;

pub const frame_object: u8 = 0;
pub const frame_array: u8 = 1;

/// Aufrufereigener Parserzustand. Der Kern schreibt hinein, besitzt ihn nicht.
pub const Cursor = extern struct {
    doc: ?[*]const u8 = null,
    doc_len: u32 = 0,
    pos: u32 = 0,
    depth: u32 = 0,
    depth_stack: ?[*]u8 = null,
    depth_capacity: u32 = 0,
    token: u32 = tok_none,
    token_start: u32 = 0,
    token_end: u32 = 0,
    reserved: u32 = 0,

    pub fn document(self: *const Cursor) ?[]const u8 {
        const ptr = self.doc orelse return null;
        return ptr[0..self.doc_len];
    }

    /// Rohbytes des aktuellen Tokens. Bei Zeichenketten ohne die
    /// Anfuehrungszeichen, Escapes bleiben unaufgeloest.
    pub fn tokenBytes(self: *const Cursor) ?[]const u8 {
        const doc = self.document() orelse return null;
        if (self.token_end > doc.len or self.token_start > self.token_end) return null;
        return doc[self.token_start..self.token_end];
    }
};

// ------------------------------------------------------------ Operationen

pub fn open(cursor: *Cursor, doc: []const u8) i32 {
    cursor.* = .{
        .doc = doc.ptr,
        .doc_len = @intCast(doc.len),
        .depth_stack = cursor.depth_stack,
        .depth_capacity = cursor.depth_capacity,
    };
    return err_ok;
}

pub fn next(cursor: *Cursor) i32 {
    const doc = cursor.document() orelse return err_bad_request;
    return scan(cursor, doc);
}

/// Setzt den Cursor auf den WERT unter dem Pfad, immer ab der Dokumentwurzel.
/// Syntax: Schluessel mit Punkt, Index mit [n]. Keine Platzhalter, keine
/// Filter, keine Suche - sonst waere das eine Abfragesprache.
pub fn select(cursor: *Cursor, path: []const u8) i32 {
    const doc = cursor.document() orelse return err_bad_request;
    cursor.pos = 0;
    cursor.depth = 0;
    const first = scan(cursor, doc);
    if (first != err_ok) return first;

    var at: usize = 0;
    while (at < path.len) {
        if (path[at] == '.') {
            at += 1;
            if (at >= path.len) return err_bad_path;
            continue;
        }
        if (path[at] == '[') {
            const close = indexOfScalar(path, at + 1, ']') orelse return err_bad_path;
            const digits = path[at + 1 .. close];
            if (digits.len == 0) return err_bad_path;
            var index: u32 = 0;
            for (digits) |ch| {
                if (ch < '0' or ch > '9') return err_bad_path;
                index = index * 10 + (ch - '0');
            }
            const rc = descendIndex(cursor, doc, index);
            if (rc != err_ok) return rc;
            at = close + 1;
            continue;
        }
        var stop = at;
        while (stop < path.len and path[stop] != '.' and path[stop] != '[') stop += 1;
        if (stop == at) return err_bad_path;
        const rc = descendKey(cursor, doc, path[at..stop]);
        if (rc != err_ok) return rc;
        at = stop;
    }
    return err_ok;
}

/// Nach array_begin oder object_begin auf das erste Element stellen. Ist der
/// Container leer, steht der Cursor danach auf dem passenden Endetoken.
pub fn enter(cursor: *Cursor) i32 {
    if (cursor.token != tok_array_begin and cursor.token != tok_object_begin) return err_wrong_token;
    const doc = cursor.document() orelse return err_bad_request;
    return scan(cursor, doc);
}

/// Ueberspringt den aktuellen Wert und stellt auf das naechste Element
/// derselben Ebene. Auf einem Endetoken passiert nichts.
pub fn nextElement(cursor: *Cursor) i32 {
    const doc = cursor.document() orelse return err_bad_request;
    if (cursor.token == tok_array_end or cursor.token == tok_object_end or cursor.token == tok_end) return err_ok;
    const rc = skipValue(cursor, doc);
    if (rc != err_ok) return rc;
    return scan(cursor, doc);
}

// -------------------------------------------------------------- Absteigen

fn descendKey(cursor: *Cursor, doc: []const u8, key: []const u8) i32 {
    if (cursor.token != tok_object_begin) return err_wrong_token;
    const level = cursor.depth;
    var rc = scan(cursor, doc);
    if (rc != err_ok) return rc;
    while (cursor.token == tok_key and cursor.depth == level) {
        const found = equalBytes(doc[cursor.token_start..cursor.token_end], key);
        rc = scan(cursor, doc);
        if (rc != err_ok) return rc;
        if (found) return err_ok;
        rc = skipValue(cursor, doc);
        if (rc != err_ok) return rc;
        rc = scan(cursor, doc);
        if (rc != err_ok) return rc;
    }
    return err_not_found;
}

fn descendIndex(cursor: *Cursor, doc: []const u8, index: u32) i32 {
    if (cursor.token != tok_array_begin) return err_wrong_token;
    const level = cursor.depth;
    var rc = scan(cursor, doc);
    if (rc != err_ok) return rc;
    var seen: u32 = 0;
    while (!(cursor.token == tok_array_end and cursor.depth == level - 1)) {
        if (cursor.token == tok_end) return err_bad_document;
        if (seen == index) return err_ok;
        rc = skipValue(cursor, doc);
        if (rc != err_ok) return rc;
        rc = scan(cursor, doc);
        if (rc != err_ok) return rc;
        seen += 1;
    }
    return err_not_found;
}

/// Steht der Cursor auf einem Containeranfang, bis zum passenden Ende laufen.
/// Auf einem Skalar ist nichts zu tun.
pub fn skipValue(cursor: *Cursor, doc: []const u8) i32 {
    if (cursor.token != tok_object_begin and cursor.token != tok_array_begin) return err_ok;
    const target = cursor.depth - 1;
    while (true) {
        const rc = scan(cursor, doc);
        if (rc != err_ok) return rc;
        if (cursor.token == tok_end) return err_bad_document;
        if ((cursor.token == tok_object_end or cursor.token == tok_array_end) and cursor.depth == target) return err_ok;
    }
}

// -------------------------------------------------------------- Tokenizer

pub fn scan(cursor: *Cursor, doc: []const u8) i32 {
    var pos: usize = cursor.pos;
    while (true) {
        while (pos < doc.len and isSpace(doc[pos])) pos += 1;
        if (pos >= doc.len) {
            cursor.pos = @intCast(pos);
            cursor.token = tok_end;
            cursor.token_start = @intCast(pos);
            cursor.token_end = @intCast(pos);
            return err_ok;
        }
        const ch = doc[pos];
        if (ch == ',' or ch == ':') {
            pos += 1;
            continue;
        }
        return switch (ch) {
            '{' => emitOpen(cursor, pos, frame_object, tok_object_begin),
            '[' => emitOpen(cursor, pos, frame_array, tok_array_begin),
            '}' => emitClose(cursor, pos, frame_object, tok_object_end),
            ']' => emitClose(cursor, pos, frame_array, tok_array_end),
            '"' => emitString(cursor, doc, pos),
            't' => emitLiteral(cursor, doc, pos, "true", tok_true),
            'f' => emitLiteral(cursor, doc, pos, "false", tok_false),
            'n' => emitLiteral(cursor, doc, pos, "null", tok_null),
            else => if (ch == '-' or (ch >= '0' and ch <= '9')) emitNumber(cursor, doc, pos) else err_bad_document,
        };
    }
}

fn emitOpen(cursor: *Cursor, pos: usize, frame: u8, token: u32) i32 {
    const stack = cursor.depth_stack orelse return err_bad_request;
    if (cursor.depth >= cursor.depth_capacity) return err_depth_exceeded;
    stack[cursor.depth] = frame;
    cursor.depth += 1;
    cursor.token = token;
    cursor.token_start = @intCast(pos);
    cursor.token_end = @intCast(pos + 1);
    cursor.pos = @intCast(pos + 1);
    return err_ok;
}

fn emitClose(cursor: *Cursor, pos: usize, frame: u8, token: u32) i32 {
    const stack = cursor.depth_stack orelse return err_bad_request;
    if (cursor.depth == 0) return err_bad_document;
    if (stack[cursor.depth - 1] != frame) return err_bad_document;
    cursor.depth -= 1;
    cursor.token = token;
    cursor.token_start = @intCast(pos);
    cursor.token_end = @intCast(pos + 1);
    cursor.pos = @intCast(pos + 1);
    return err_ok;
}

/// Die Spanne schliesst die Anfuehrungszeichen NICHT ein. Escapes bleiben roh
/// stehen; der Kern dekodiert nicht, und der Pfadvergleich arbeitet deshalb
/// auf den Rohbytes des Schluessels.
fn emitString(cursor: *Cursor, doc: []const u8, pos: usize) i32 {
    var i = pos + 1;
    while (i < doc.len) {
        const ch = doc[i];
        if (ch == '\\') {
            i += 2;
            continue;
        }
        if (ch == '"') break;
        i += 1;
    }
    if (i >= doc.len) return err_bad_document;

    cursor.token_start = @intCast(pos + 1);
    cursor.token_end = @intCast(i);
    cursor.pos = @intCast(i + 1);

    // Schluessel oder Zeichenkette entscheidet das naechste Zeichen: folgt ein
    // Doppelpunkt, war es ein Membername.
    var look = i + 1;
    while (look < doc.len and isSpace(doc[look])) look += 1;
    const in_object = blk: {
        const stack = cursor.depth_stack orelse break :blk false;
        if (cursor.depth == 0) break :blk false;
        break :blk stack[cursor.depth - 1] == frame_object;
    };
    cursor.token = if (in_object and look < doc.len and doc[look] == ':') tok_key else tok_string;
    return err_ok;
}

fn emitLiteral(cursor: *Cursor, doc: []const u8, pos: usize, comptime text: []const u8, token: u32) i32 {
    if (pos + text.len > doc.len) return err_bad_document;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (doc[pos + i] != text[i]) return err_bad_document;
    }
    cursor.token = token;
    cursor.token_start = @intCast(pos);
    cursor.token_end = @intCast(pos + text.len);
    cursor.pos = @intCast(pos + text.len);
    return err_ok;
}

/// Zahlen werden als Rohausschnitt gemeldet, nicht gerechnet. Damit braucht
/// der Kern keine Gleitkommaarithmetik, und ein Feld, das den Aufrufer nicht
/// interessiert, kostet nichts.
fn emitNumber(cursor: *Cursor, doc: []const u8, pos: usize) i32 {
    var i = pos;
    if (i < doc.len and doc[i] == '-') i += 1;
    const digits_start = i;
    while (i < doc.len and doc[i] >= '0' and doc[i] <= '9') i += 1;
    if (i == digits_start) return err_bad_document;
    if (i < doc.len and doc[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < doc.len and doc[i] >= '0' and doc[i] <= '9') i += 1;
        if (i == frac_start) return err_bad_document;
    }
    if (i < doc.len and (doc[i] == 'e' or doc[i] == 'E')) {
        i += 1;
        if (i < doc.len and (doc[i] == '+' or doc[i] == '-')) i += 1;
        const exp_start = i;
        while (i < doc.len and doc[i] >= '0' and doc[i] <= '9') i += 1;
        if (i == exp_start) return err_bad_document;
    }
    cursor.token = tok_number;
    cursor.token_start = @intCast(pos);
    cursor.token_end = @intCast(i);
    cursor.pos = @intCast(i);
    return err_ok;
}

// ---------------------------------------------------------------- Helfer

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn equalBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn indexOfScalar(haystack: []const u8, from: usize, needle: u8) ?usize {
    var i = from;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    return null;
}

// ------------------------------------------------------------- Aendern

/// Bytebereich eines VOLLSTAENDIGEN Wertes im Dokument.
pub const Span = struct { start: u32, end: u32 };

/// Anders als token_start/token_end umfasst die Spanne bei Zeichenketten die
/// Anfuehrungszeichen und bei Containern alles bis zur schliessenden Klammer.
/// Genau das braucht eine Ersetzung.
pub fn valueSpan(cursor: *const Cursor) ?Span {
    const doc = cursor.document() orelse return null;
    switch (cursor.token) {
        tok_string => {
            if (cursor.token_start == 0 or cursor.token_end >= doc.len) return null;
            return .{ .start = cursor.token_start - 1, .end = cursor.token_end + 1 };
        },
        tok_number, tok_true, tok_false, tok_null => return .{ .start = cursor.token_start, .end = cursor.token_end },
        tok_object_begin, tok_array_begin => {
            // Auf einer KOPIE laufen, damit der Cursor des Aufrufers stehen
            // bleibt. Das gemeinsame Tiefenfeld ist dabei unkritisch: Die
            // Kopie schreibt nur auf Ebenen ab cursor.depth aufwaerts.
            var probe = cursor.*;
            if (skipValue(&probe, doc) != err_ok) return null;
            return .{ .start = cursor.token_start, .end = probe.token_end };
        },
        else => return null,
    }
}

/// Ersetzt den Wert unter dem Pfad. Unberuehrte Bereiche werden byteweise
/// durchkopiert, Formatierung und Schluesselreihenfolge des restlichen
/// Dokuments bleiben also byteidentisch.
///
/// value ist ROHER JSON-Text. Damit braucht der Kern keine typisierten
/// Wertkonstruktoren und kann ein ganzes Objekt so einfach setzen wie eine
/// Zahl - und muss den Wert auch nicht deuten.
pub fn set(cursor: *Cursor, path: []const u8, value: []const u8, out: []u8, written: *u32) i32 {
    const rc = select(cursor, path);
    if (rc != err_ok) return rc;
    const doc = cursor.document() orelse return err_bad_request;
    const span = valueSpan(cursor) orelse return err_bad_document;
    return splice(doc, span.start, span.end, value, out, written);
}

/// Entfernt einen Member oder ein Element samt genau einem angrenzenden
/// Komma. Ohne diese Kommapflege entstuende ungueltiges JSON - das ist die
/// Stelle, an der solche Implementierungen ueblicherweise scheitern.
pub fn remove(cursor: *Cursor, path: []const u8, out: []u8, written: *u32) i32 {
    const rc = select(cursor, path);
    if (rc != err_ok) return rc;
    const doc = cursor.document() orelse return err_bad_request;
    const span = valueSpan(cursor) orelse return err_bad_document;

    var start = span.start;
    const member = memberKeyStart(doc, span.start);
    if (member) |key_start| start = key_start;

    var cut_start = start;
    var cut_end = span.end;

    // Rueckwaerts ueber Leerraum bis zum vorherigen bedeutungstragenden Byte.
    var back = start;
    while (back > 0 and isSpace(doc[back - 1])) back -= 1;
    if (back > 0 and doc[back - 1] == ',') {
        // Nicht das erste Element: das TRENNENDE Komma davor faellt mit weg.
        cut_start = back - 1;
    } else {
        // Erstes Element: den Leerraum davor mitnehmen und, falls ein
        // weiteres Element folgt, dessen trennendes Komma.
        cut_start = back;
        var fwd = span.end;
        while (fwd < doc.len and isSpace(doc[fwd])) fwd += 1;
        if (fwd < doc.len and doc[fwd] == ',') cut_end = fwd + 1;
    }
    return splice(doc, cut_start, cut_end, "", out, written);
}

/// Fuegt einen Wert als LETZTES Element in das Array unter dem Pfad ein. Die
/// Einrueckung der Geschwister wird uebernommen; ein leeres Array bekommt die
/// Einrueckung der oeffnenden Klammer plus zwei Leerzeichen.
///
/// Existiert der Elterncontainer nicht, ist das ein Fehler - Zwischenebenen
/// werden nicht erfunden.
pub fn insert(cursor: *Cursor, path: []const u8, value: []const u8, out: []u8, written: *u32) i32 {
    const rc = select(cursor, path);
    if (rc != err_ok) return rc;
    if (cursor.token != tok_array_begin) return err_wrong_token;
    const doc = cursor.document() orelse return err_bad_request;
    const span = valueSpan(cursor) orelse return err_bad_document;

    const close = span.end - 1; // Position der schliessenden Klammer
    var last = close;
    while (last > span.start and isSpace(doc[last - 1])) last -= 1;
    const empty = last == span.start + 1;

    var buffer: [80]u8 = undefined;
    var len: usize = 0;
    if (!empty) {
        buffer[len] = ',';
        len += 1;
    }
    const indent = lineIndent(doc, if (empty) span.start else lastElementStart(doc, span.start, last));
    if (indent.newline) {
        buffer[len] = '\n';
        len += 1;
        var i: usize = 0;
        const width = if (empty) indent.width + 2 else indent.width;
        while (i < width and len < buffer.len) : (i += 1) {
            buffer[len] = ' ';
            len += 1;
        }
    }

    // Zwei Einfuegungen an derselben Stelle: erst der Trenner, dann der Wert.
    if (written.* != 0) written.* = 0;
    return spliceTwo(doc, last, last, buffer[0..len], value, out, written);
}

const Indent = struct { newline: bool, width: u32 };

/// Einrueckung der ZEILE, in der position steht - nicht des Leerraums direkt
/// davor. Der Unterschied ist entscheidend: Bei "entries": [] steht vor der
/// Klammer ein Doppelpunkt, die Zeile ist aber trotzdem eingerueckt.
///
/// newline=false heisst: vor position gibt es keinen Zeilenumbruch, das
/// Dokument steht also auf einer Zeile. Dann wird auch beim Einfuegen nicht
/// umgebrochen, sonst wuerde eine einzeilige Datei ploetzlich mehrzeilig.
fn lineIndent(doc: []const u8, position: u32) Indent {
    var start = position;
    while (start > 0 and doc[start - 1] != '\n') start -= 1;
    if (start == 0) return .{ .newline = false, .width = 0 };
    var width: u32 = 0;
    var i = start;
    while (i < doc.len and doc[i] == ' ') : (i += 1) width += 1;
    return .{ .newline = true, .width = width };
}

/// Erstes Zeichen des letzten Arrayelements, gesucht ab dessen Ende. Die
/// Grenze ist das trennende Komma oder die oeffnende Klammer; danach wird
/// Leerraum uebersprungen, damit wirklich das Element selbst herauskommt.
fn lastElementStart(doc: []const u8, array_start: u32, element_end: u32) u32 {
    var i = element_end;
    var depth: i32 = 0;
    var boundary = array_start + 1;
    while (i > array_start + 1) {
        const ch = doc[i - 1];
        if (ch == '}' or ch == ']') depth += 1;
        if (ch == '{' or ch == '[') {
            if (depth == 0) {
                boundary = i;
                break;
            }
            depth -= 1;
        }
        if (depth == 0 and ch == ',') {
            boundary = i;
            break;
        }
        i -= 1;
    }
    var s = boundary;
    while (s < doc.len and isSpace(doc[s])) s += 1;
    return s;
}

/// Steht vor dem Wert ein Membername, dessen oeffnendes Anfuehrungszeichen
/// liefern. Sonst null - dann ist es ein Arrayelement.
fn memberKeyStart(doc: []const u8, value_start: u32) ?u32 {
    var i = value_start;
    while (i > 0 and isSpace(doc[i - 1])) i -= 1;
    if (i == 0 or doc[i - 1] != ':') return null;
    i -= 1;
    while (i > 0 and isSpace(doc[i - 1])) i -= 1;
    if (i == 0 or doc[i - 1] != '"') return null;
    i -= 1;
    while (i > 0) {
        if (doc[i - 1] == '"') {
            var escapes: u32 = 0;
            var j = i - 1;
            while (j > 0 and doc[j - 1] == '\\') : (j -= 1) escapes += 1;
            if (escapes % 2 == 0) return i - 1;
        }
        i -= 1;
    }
    return null;
}

fn splice(doc: []const u8, cut_start: u32, cut_end: u32, value: []const u8, out: []u8, written: *u32) i32 {
    return spliceTwo(doc, cut_start, cut_end, value, "", out, written);
}

/// Kern jeder Aenderung: Vorderteil, Einfuegung, Hinterteil. Passt das
/// Ergebnis nicht, wird die BENOETIGTE Groesse gemeldet und der Aufrufer
/// wiederholt - keine stille Allokation.
fn spliceTwo(doc: []const u8, cut_start: u32, cut_end: u32, first: []const u8, second: []const u8, out: []u8, written: *u32) i32 {
    if (cut_start > cut_end or cut_end > doc.len) return err_bad_document;
    const total = @as(usize, cut_start) + first.len + second.len + (doc.len - cut_end);
    written.* = @intCast(total);
    if (total > out.len) return err_output_too_small;

    var at: usize = 0;
    var i: usize = 0;
    while (i < cut_start) : (i += 1) {
        out[at] = doc[i];
        at += 1;
    }
    for (first) |ch| {
        out[at] = ch;
        at += 1;
    }
    for (second) |ch| {
        out[at] = ch;
        at += 1;
    }
    i = cut_end;
    while (i < doc.len) : (i += 1) {
        out[at] = doc[i];
        at += 1;
    }
    return err_ok;
}

// ---------------------------------------------------------- Inline-Tests

const std = @import("std");

/// Baut einen Cursor mit aufrufereigenem Tiefenfeld, so wie es ein Programm
/// auch tun wuerde.
fn testCursor(stack: []u8, doc: []const u8) Cursor {
    var cursor = Cursor{ .depth_stack = stack.ptr, .depth_capacity = @intCast(stack.len) };
    _ = open(&cursor, doc);
    return cursor;
}

test "tokenizer reports exact byte spans and separates key from string" {
    const doc =
        \\{"name": "SYSINFO", "kind": "R4X"}
    ;
    var stack: [8]u8 = undefined;
    var cursor = testCursor(&stack, doc);

    try std.testing.expectEqual(err_ok, scan(&cursor, doc));
    try std.testing.expectEqual(tok_object_begin, cursor.token);

    try std.testing.expectEqual(err_ok, scan(&cursor, doc));
    try std.testing.expectEqual(tok_key, cursor.token);
    try std.testing.expectEqualStrings("name", cursor.tokenBytes().?);

    try std.testing.expectEqual(err_ok, scan(&cursor, doc));
    try std.testing.expectEqual(tok_string, cursor.token);
    try std.testing.expectEqualStrings("SYSINFO", cursor.tokenBytes().?);
    // Die Spanne muss OHNE Anfuehrungszeichen stehen, sonst kann ein spaeteres
    // set() den Wert nicht passgenau ersetzen.
    try std.testing.expectEqual(doc[cursor.token_start - 1], '"');
    try std.testing.expectEqual(doc[cursor.token_end], '"');
}

test "selector resolves keys and indices across skipped containers" {
    const doc =
        \\{"schema":1,"entries":[{"name":"A","v":1},{"name":"B","nested":{"deep":[9,8]},"v":2}],"count":2}
    ;
    var stack: [16]u8 = undefined;
    var cursor = testCursor(&stack, doc);

    try std.testing.expectEqual(err_ok, select(&cursor, "count"));
    try std.testing.expectEqualStrings("2", cursor.tokenBytes().?);

    try std.testing.expectEqual(err_ok, select(&cursor, "entries[0].name"));
    try std.testing.expectEqualStrings("A", cursor.tokenBytes().?);

    // Der zweite Eintrag liegt hinter einem verschachtelten Objekt - der
    // Selektor muss es vollstaendig ueberspringen, nicht hineinfallen.
    try std.testing.expectEqual(err_ok, select(&cursor, "entries[1].v"));
    try std.testing.expectEqualStrings("2", cursor.tokenBytes().?);

    try std.testing.expectEqual(err_ok, select(&cursor, "entries[1].nested.deep[1]"));
    try std.testing.expectEqualStrings("8", cursor.tokenBytes().?);
}

test "selector reports a missing key or index instead of guessing" {
    const doc =
        \\{"entries":[{"name":"A"}]}
    ;
    var stack: [8]u8 = undefined;
    var cursor = testCursor(&stack, doc);

    try std.testing.expectEqual(err_not_found, select(&cursor, "absent"));
    try std.testing.expectEqual(err_not_found, select(&cursor, "entries[7]"));
    try std.testing.expectEqual(err_wrong_token, select(&cursor, "entries.name"));
    try std.testing.expectEqual(err_bad_path, select(&cursor, "entries[]"));
}

test "iterator walks an array without restarting from the document head" {
    const doc =
        \\{"entries":[{"n":"A"},{"n":"B"},{"n":"C"}]}
    ;
    var stack: [16]u8 = undefined;
    var cursor = testCursor(&stack, doc);

    try std.testing.expectEqual(err_ok, select(&cursor, "entries"));
    try std.testing.expectEqual(tok_array_begin, cursor.token);
    try std.testing.expectEqual(err_ok, enter(&cursor));

    var namen: [3][]const u8 = undefined;
    var count: usize = 0;
    while (cursor.token != tok_array_end and count < namen.len) {
        // Jedes Element ist ein Objekt; sein Wert steht unter n.
        var inner = cursor;
        try std.testing.expectEqual(err_ok, enter(&inner));
        try std.testing.expectEqual(tok_key, inner.token);
        try std.testing.expectEqual(err_ok, scan(&inner, doc));
        namen[count] = inner.tokenBytes().?;
        count += 1;
        try std.testing.expectEqual(err_ok, nextElement(&cursor));
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("A", namen[0]);
    try std.testing.expectEqualStrings("B", namen[1]);
    try std.testing.expectEqualStrings("C", namen[2]);
}

test "the depth limit belongs to the caller and is reported visibly" {
    const doc =
        \\{"a":{"b":{"c":1}}}
    ;
    var eng: [2]u8 = undefined;
    var cursor = testCursor(&eng, doc);
    // Zwei Ebenen erlaubt, drei verlangt: der Fehler ist sichtbar, nicht still.
    try std.testing.expectEqual(err_depth_exceeded, select(&cursor, "a.b.c"));

    var weit: [8]u8 = undefined;
    var ok_cursor = testCursor(&weit, doc);
    try std.testing.expectEqual(err_ok, select(&ok_cursor, "a.b.c"));
    try std.testing.expectEqualStrings("1", ok_cursor.tokenBytes().?);
}

test "malformed documents are rejected instead of guessed" {
    var stack: [8]u8 = undefined;
    const faelle = [_][]const u8{
        "{\"a\":", // abgeschnitten
        "{\"a\":\"unbeendet", // offene Zeichenkette
        "{\"a\":tru}", // falsches Literal
        "{\"a\":1.}", // Zahl ohne Nachkommastelle
        "[1,2}", // falsche Klammer
    };
    for (faelle) |doc| {
        var cursor = testCursor(&stack, doc);
        // Erst lesen, dann pruefen: nach open() steht der Cursor auf
        // tok_none, eine Kopfbedingung auf tok_end liefe nie los.
        var rc = scan(&cursor, doc);
        var guard: usize = 0;
        while (rc == err_ok and cursor.token != tok_end and guard < 32) : (guard += 1) {
            rc = scan(&cursor, doc);
        }
        // Entweder meldet der Kern einen Fehler, oder das Dokument endet mit
        // offenen Klammern - beides ist eine Ablehnung, kein stilles Raten.
        try std.testing.expect(rc != err_ok or cursor.depth != 0);
    }
}

test "escapes inside a value do not break the span" {
    const doc =
        \\{"pfad":"C:\\R4OS\\CONFIG","q":"er sagte \"hallo\""}
    ;
    var stack: [8]u8 = undefined;
    var cursor = testCursor(&stack, doc);

    try std.testing.expectEqual(err_ok, select(&cursor, "q"));
    // Roh, also mit Escapes - der Kern dekodiert bewusst nicht.
    try std.testing.expectEqualStrings("er sagte \\\"hallo\\\"", cursor.tokenBytes().?);

    try std.testing.expectEqual(err_ok, select(&cursor, "pfad"));
    try std.testing.expectEqualStrings("C:\\\\R4OS\\\\CONFIG", cursor.tokenBytes().?);
}

/// Dokument im Stil unserer erzeugten Inventare: zwei Leerzeichen Einrueckung.
const sample_doc =
    \\{
    \\  "schema": 1,
    \\  "count": 2,
    \\  "entries": [
    \\    {
    \\      "name": "A",
    \\      "version": "0.1.0"
    \\    },
    \\    {
    \\      "name": "B",
    \\      "version": "0.2.0"
    \\    }
    \\  ]
    \\}
;

/// Prueft, dass das Ergebnis noch gueltiges JSON ist. Eine Aenderung, die ein
/// unlesbares Dokument hinterlaesst, waere schlimmer als gar keine.
fn expectParses(text: []const u8) !void {
    var stack: [16]u8 = undefined;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, text);
    var rc = scan(&cursor, text);
    var guard: usize = 0;
    while (rc == err_ok and cursor.token != tok_end and guard < 4096) : (guard += 1) {
        rc = scan(&cursor, text);
    }
    try std.testing.expectEqual(err_ok, rc);
    try std.testing.expectEqual(@as(u32, 0), cursor.depth);
}

test "set replaces a value and leaves every untouched byte identical" {
    var stack: [16]u8 = undefined;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, sample_doc);

    var out: [512]u8 = undefined;
    var written: u32 = 0;
    try std.testing.expectEqual(err_ok, set(&cursor, "entries[1].version", "\"9.9.9\"", &out, &written));
    const result = out[0..written];
    try expectParses(result);

    // Genau eine Stelle darf sich unterscheiden: die Laenge bleibt gleich,
    // weil "0.2.0" und "9.9.9" gleich lang sind - also muss der Rest Byte
    // fuer Byte stimmen.
    try std.testing.expectEqual(sample_doc.len, result.len);
    var abweichungen: usize = 0;
    for (result, 0..) |ch, i| {
        if (ch != sample_doc[i]) abweichungen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), abweichungen);

    // Und der neue Wert ist auch wirklich lesbar.
    var check = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&check, result);
    try std.testing.expectEqual(err_ok, select(&check, "entries[1].version"));
    try std.testing.expectEqualStrings("9.9.9", check.tokenBytes().?);
}

test "set accepts a whole object as raw JSON text" {
    var stack: [16]u8 = undefined;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, sample_doc);

    var out: [512]u8 = undefined;
    var written: u32 = 0;
    try std.testing.expectEqual(err_ok, set(&cursor, "entries[0]", "{\"name\":\"Z\"}", &out, &written));
    const result = out[0..written];
    try expectParses(result);

    var check = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&check, result);
    try std.testing.expectEqual(err_ok, select(&check, "entries[0].name"));
    try std.testing.expectEqualStrings("Z", check.tokenBytes().?);
    // Der zweite Eintrag ist unberuehrt nachgerueckt.
    try std.testing.expectEqual(err_ok, select(&check, "entries[1].name"));
    try std.testing.expectEqualStrings("B", check.tokenBytes().?);
}

test "remove keeps the document valid at first, middle and last position" {
    const drei =
        \\{"a":1,"b":2,"c":3}
    ;
    var stack: [8]u8 = undefined;
    var out: [128]u8 = undefined;
    var written: u32 = 0;

    const faelle = [_]struct { path: []const u8, gone: []const u8, left: []const u8 }{
        .{ .path = "a", .gone = "a", .left = "b" },
        .{ .path = "b", .gone = "b", .left = "c" },
        .{ .path = "c", .gone = "c", .left = "a" },
    };
    for (faelle) |fall| {
        var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
        _ = open(&cursor, drei);
        try std.testing.expectEqual(err_ok, remove(&cursor, fall.path, &out, &written));
        const result = out[0..written];
        try expectParses(result);

        var check = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
        _ = open(&check, result);
        try std.testing.expectEqual(err_not_found, select(&check, fall.gone));
        _ = open(&check, result);
        try std.testing.expectEqual(err_ok, select(&check, fall.left));
    }
}

test "remove of the only member leaves an empty object" {
    const eins =
        \\{"a":1}
    ;
    var stack: [8]u8 = undefined;
    var out: [64]u8 = undefined;
    var written: u32 = 0;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, eins);
    try std.testing.expectEqual(err_ok, remove(&cursor, "a", &out, &written));
    try std.testing.expectEqualStrings("{}", out[0..written]);
}

test "insert appends to an array and matches the sibling indentation" {
    var stack: [16]u8 = undefined;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, sample_doc);

    var out: [512]u8 = undefined;
    var written: u32 = 0;
    try std.testing.expectEqual(err_ok, insert(&cursor, "entries", "{\"name\": \"C\"}", &out, &written));
    const result = out[0..written];
    try expectParses(result);

    var check = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&check, result);
    try std.testing.expectEqual(err_ok, select(&check, "entries[2].name"));
    try std.testing.expectEqualStrings("C", check.tokenBytes().?);
    // Die beiden bestehenden Eintraege bleiben unangetastet.
    _ = open(&check, result);
    try std.testing.expectEqual(err_ok, select(&check, "entries[0].name"));
    try std.testing.expectEqualStrings("A", check.tokenBytes().?);

    // Das neue Element steht auf einer eigenen Zeile mit derselben
    // Einrueckung wie seine Geschwister.
    try std.testing.expect(indexOfSub(result, "\n    {\"name\": \"C\"}") != null);
}

test "insert into an empty array indents one level deeper" {
    const leer =
        \\{
        \\  "entries": []
        \\}
    ;
    var stack: [8]u8 = undefined;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, leer);

    var out: [128]u8 = undefined;
    var written: u32 = 0;
    try std.testing.expectEqual(err_ok, insert(&cursor, "entries", "7", &out, &written));
    const result = out[0..written];
    try expectParses(result);
    try std.testing.expect(indexOfSub(result, "\n    7") != null);

    var check = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&check, result);
    try std.testing.expectEqual(err_ok, select(&check, "entries[0]"));
    try std.testing.expectEqualStrings("7", check.tokenBytes().?);
}

test "insert refuses a missing parent instead of inventing one" {
    var stack: [16]u8 = undefined;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, sample_doc);
    var out: [512]u8 = undefined;
    var written: u32 = 0;
    try std.testing.expectEqual(err_not_found, insert(&cursor, "missing", "1", &out, &written));
    // In ein Objekt wird nicht eingefuegt - das waere eine andere Operation.
    try std.testing.expectEqual(err_wrong_token, insert(&cursor, "entries[0]", "1", &out, &written));
}

test "a short output buffer reports the required size instead of truncating" {
    var stack: [16]u8 = undefined;
    var cursor = Cursor{ .depth_stack = &stack, .depth_capacity = stack.len };
    _ = open(&cursor, sample_doc);

    var winzig: [8]u8 = undefined;
    var written: u32 = 0;
    try std.testing.expectEqual(err_output_too_small, set(&cursor, "count", "3", &winzig, &written));
    try std.testing.expectEqual(@as(u32, sample_doc.len), written);

    // Mit der gemeldeten Groesse gelingt der zweite Versuch.
    var passend: [sample_doc.len]u8 = undefined;
    _ = open(&cursor, sample_doc);
    try std.testing.expectEqual(err_ok, set(&cursor, "count", "3", &passend, &written));
    try expectParses(passend[0..written]);
}

fn indexOfSub(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (equalBytes(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}
