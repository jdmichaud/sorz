//! The WebSocket protocol (RFC 6455) as the native transport speaks it, without I/O: the opening
//! handshake of both sides over HTTP/1.1, the frame headers, the masking, and the static files'
//! responses. `net.zig` runs it over sockets.
//!
//! Only what network play needs: binary messages (a text message is refused with close code
//! 1003), fragmentation, ping and pong, close. No extension and no subprotocol is negotiated.
const std = @import("std");

/// The key suffix of the opening handshake (RFC 6455 section 1.3).
pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// The longest head of an HTTP request or response that the transport reads.
pub const max_head_len = 8 * 1024;

/// `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key`: base64(SHA-1(key ++ guid)).
pub fn acceptKey(key: []const u8) [28]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// A client's `Sec-WebSocket-Key`: 16 random bytes in base64.
pub fn clientKey(random: [16]u8) [24]u8 {
    var out: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &random);
    return out;
}

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    pub fn isControl(op: Opcode) bool {
        return @backingInt(op) & 8 != 0;
    }
};

/// The close codes the transport sends (RFC 6455 section 7.4.1).
pub const CloseCode = struct {
    pub const normal: u16 = 1000;
    pub const going_away: u16 = 1001;
    pub const protocol_error: u16 = 1002;
    pub const unsupported_data: u16 = 1003;
    pub const too_big: u16 = 1009;
};

pub const Header = struct {
    fin: bool,
    opcode: Opcode,
    mask: ?[4]u8,
    len: u64,
    /// The header's own length in bytes (2 to 14).
    size: usize,
};

pub const ProtocolError = error{Protocol};

/// Reads a frame header at the start of `bytes`: null while more bytes are needed. Refuses
/// reserved bits (no extension is negotiated), unknown opcodes, a control frame that is
/// fragmented or longer than 125 bytes, and a length not written in its shortest form.
pub fn parseHeader(bytes: []const u8) ProtocolError!?Header {
    if (bytes.len < 2) return null;
    const b0 = bytes[0];
    const b1 = bytes[1];
    if (b0 & 0x70 != 0) return error.Protocol;
    const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0))));
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        _ => return error.Protocol,
    }
    const fin = b0 & 0x80 != 0;
    const masked = b1 & 0x80 != 0;
    const short: u7 = @truncate(b1);
    var size: usize = 2;
    var len: u64 = short;
    if (short == 126) {
        if (bytes.len < 4) return null;
        len = std.mem.readInt(u16, bytes[2..4], .big);
        if (len < 126) return error.Protocol;
        size = 4;
    } else if (short == 127) {
        if (bytes.len < 10) return null;
        len = std.mem.readInt(u64, bytes[2..10], .big);
        if (len >> 63 != 0 or len <= 0xFFFF) return error.Protocol;
        size = 10;
    }
    if (opcode.isControl() and (!fin or len > 125)) return error.Protocol;
    var mask: ?[4]u8 = null;
    if (masked) {
        if (bytes.len < size + 4) return null;
        mask = bytes[size..][0..4].*;
        size += 4;
    }
    return .{ .fin = fin, .opcode = opcode, .mask = mask, .len = len, .size = size };
}

/// Writes a frame header into `out` and returns its length.
pub fn writeHeader(out: *[14]u8, fin: bool, opcode: Opcode, len: u64, mask: ?[4]u8) usize {
    out[0] = (if (fin) @as(u8, 0x80) else 0) | @backingInt(opcode);
    const m: u8 = if (mask != null) 0x80 else 0;
    var size: usize = 2;
    if (len < 126) {
        out[1] = m | @as(u8, @intCast(len));
    } else if (len <= 0xFFFF) {
        out[1] = m | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(len), .big);
        size = 4;
    } else {
        out[1] = m | 127;
        std.mem.writeInt(u64, out[2..10], len, .big);
        size = 10;
    }
    if (mask) |k| {
        out[size..][0..4].* = k;
        size += 4;
    }
    return size;
}

/// XORs `bytes` with the mask, from the payload's byte `offset`; masking and unmasking are the
/// same.
pub fn applyMask(bytes: []u8, mask: [4]u8, offset: usize) void {
    for (bytes, 0..) |*b, i| b.* ^= mask[(offset + i) & 3];
}

/// The payload of a close frame with `code`.
pub fn closePayload(code: u16) [2]u8 {
    var out: [2]u8 = undefined;
    std.mem.writeInt(u16, &out, code, .big);
    return out;
}

// --- HTTP ----------------------------------------------------------------------------------------

/// The end of an HTTP head (`\r\n\r\n`) in `bytes`: the head's length, or null.
pub fn headEnd(bytes: []const u8) ?usize {
    const i = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    return i + 4;
}

/// The value of header `name` (case-insensitive) in an HTTP head, trimmed.
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // the request or status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Whether a comma-separated header value holds `token` (case-insensitive).
fn hasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |t| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t"), token)) return true;
    return false;
}

pub const Request = struct {
    method: []const u8,
    /// The path, without its query.
    path: []const u8,
    /// `Upgrade: websocket` with `Connection: upgrade`.
    upgrade: bool,
    key: ?[]const u8,
    version: ?[]const u8,
};

/// Reads a request's head (up to and with its blank line).
pub fn parseRequest(head: []const u8) error{BadRequest}!Request {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const protocol = parts.next() orelse return error.BadRequest;
    if (parts.next() != null or !std.mem.startsWith(u8, protocol, "HTTP/1.")) return error.BadRequest;
    if (method.len == 0 or target.len == 0 or target[0] != '/') return error.BadRequest;
    const path = target[0 .. std.mem.indexOfAny(u8, target, "?#") orelse target.len];
    const upgrade = if (headerValue(head, "Upgrade")) |u| hasToken(u, "websocket") else false;
    const connection = if (headerValue(head, "Connection")) |c| hasToken(c, "upgrade") else false;
    return .{
        .method = method,
        .path = path,
        .upgrade = upgrade and connection,
        .key = headerValue(head, "Sec-WebSocket-Key"),
        .version = headerValue(head, "Sec-WebSocket-Version"),
    };
}

/// A client's opening handshake.
pub fn writeUpgradeRequest(w: *std.Io.Writer, host: []const u8, port: u16, path: []const u8, key: []const u8) std.Io.Writer.Error!void {
    const bracket = std.mem.indexOfScalar(u8, host, ':') != null;
    try w.print("GET {s} HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{
        path, if (bracket) "[" else "", host, if (bracket) "]" else "", port, key,
    });
}

/// The server's answer to a valid opening handshake.
pub fn writeUpgradeResponse(w: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n\r\n", .{&acceptKey(key)});
}

/// Checks the server's answer to the client's handshake with `key`.
pub fn checkUpgradeResponse(head: []const u8, key: []const u8) error{Refused}!void {
    if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.Refused;
    const upgrade = headerValue(head, "Upgrade") orelse return error.Refused;
    const connection = headerValue(head, "Connection") orelse return error.Refused;
    if (!hasToken(upgrade, "websocket") or !hasToken(connection, "upgrade")) return error.Refused;
    const accept = headerValue(head, "Sec-WebSocket-Accept") orelse return error.Refused;
    if (!std.mem.eql(u8, accept, &acceptKey(key))) return error.Refused;
    if (headerValue(head, "Sec-WebSocket-Extensions") != null) return error.Refused;
}

/// A response without a body beyond `text`, which closes the connection.
pub fn writeStatus(w: *std.Io.Writer, status: []const u8, extra_headers: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try w.print("HTTP/1.1 {s}\r\n{s}Content-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n{s}", .{ status, extra_headers, text.len, text });
}

/// The file of the browser build that a GET of `path` names: `index.html` for `/`, else a
/// flat name of letters, digits, `.`, `_` and `-` that does not start with a dot. Null for any
/// other path, which the server answers with 404.
pub fn staticName(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/")) return "index.html";
    const name = path[1..];
    if (name.len == 0 or name.len > 64 or name[0] == '.') return null;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return null;
    }
    return name;
}

/// The content type of a served file, by its extension.
pub fn contentType(name: []const u8) []const u8 {
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".json", "application/json" },
        .{ ".tmj", "application/json" },
        .{ ".wav", "audio/wav" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".png", "image/png" },
        .{ ".ico", "image/x-icon" },
        .{ ".txt", "text/plain; charset=utf-8" },
    };
    for (types) |t| if (std.ascii.endsWithIgnoreCase(name, t[0])) return t[1];
    return "application/octet-stream";
}

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

test "the accept key of RFC 6455's example" {
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
    try testing.expectEqualStrings("AAECAwQFBgcICQoLDA0ODw==", &clientKey(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }));
}

test "frame headers round trip in their three length forms, masked or not" {
    for ([_]u64{ 0, 125, 126, 0xFFFF, 0x10000, 1 << 40 }) |len| {
        for ([_]?[4]u8{ null, .{ 1, 2, 3, 4 } }) |mask| {
            var buf: [14]u8 = undefined;
            const n = writeHeader(&buf, true, .binary, len, mask);
            // Short input asks for more.
            try testing.expectEqual(@as(?Header, null), try parseHeader(buf[0 .. n - 1]));
            const h = (try parseHeader(buf[0..n])).?;
            try testing.expectEqual(len, h.len);
            try testing.expectEqual(n, h.size);
            try testing.expectEqual(Opcode.binary, h.opcode);
            try testing.expectEqual(mask, h.mask);
        }
    }
}

test "malformed frame headers are refused" {
    // A reserved bit, an unknown opcode, a fragmented or long control frame, a length not in
    // its shortest form.
    for ([_][]const u8{
        &.{ 0xC2, 0x00 },
        &.{ 0x83, 0x00 },
        &.{ 0x09, 0x00 },
        &.{ 0x89, 126, 0, 200 },
        &.{ 0x82, 126, 0, 100 },
        &.{ 0x82, 127, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF },
        &.{ 0x82, 127, 0x80, 0, 0, 0, 0, 1, 0, 0 },
    }) |bytes| try testing.expectError(error.Protocol, parseHeader(bytes));
}

test "masking is its own inverse, from any offset" {
    var data = "network play".*;
    const mask = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
    applyMask(data[0..5], mask, 0);
    applyMask(data[5..], mask, 5);
    try testing.expect(!std.mem.eql(u8, &data, "network play"));
    applyMask(&data, mask, 0);
    try testing.expectEqualStrings("network play", &data);
}

test "the opening handshake, both sides" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeUpgradeRequest(&w, "::1", 7000, "/", "dGhlIHNhbXBsZSBub25jZQ==");
    const head = w.buffered();
    try testing.expectEqual(head.len, headEnd(head).?);
    const req = try parseRequest(head);
    try testing.expectEqualStrings("GET", req.method);
    try testing.expectEqualStrings("/", req.path);
    try testing.expect(req.upgrade);
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", req.key.?);
    try testing.expectEqualStrings("13", req.version.?);
    try testing.expectEqualStrings("[::1]:7000", headerValue(head, "host").?);

    var rbuf: [256]u8 = undefined;
    var rw = std.Io.Writer.fixed(&rbuf);
    try writeUpgradeResponse(&rw, req.key.?);
    try checkUpgradeResponse(rw.buffered(), "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectError(error.Refused, checkUpgradeResponse(rw.buffered(), "AAAAAAAAAAAAAAAAAAAAAA=="));
    try testing.expectError(error.Refused, checkUpgradeResponse("HTTP/1.1 404 Not Found\r\n\r\n", "x"));

    const plain = try parseRequest("GET /sorz.wasm?v=2 HTTP/1.1\r\nHost: h\r\nConnection: keep-alive, Upgrade\r\n\r\n");
    try testing.expectEqualStrings("/sorz.wasm", plain.path);
    try testing.expect(!plain.upgrade);
    try testing.expectError(error.BadRequest, parseRequest("GET\r\n\r\n"));
    try testing.expectError(error.BadRequest, parseRequest("GET x HTTP/1.1\r\n\r\n"));
}

test "the static files: flat names only, and their types" {
    try testing.expectEqualStrings("index.html", staticName("/").?);
    try testing.expectEqualStrings("sorz.wasm", staticName("/sorz.wasm").?);
    for ([_][]const u8{ "/../x", "/a/b", "/.hidden", "/%2e%2e", "//" }) |p| {
        try testing.expectEqual(@as(?[]const u8, null), staticName(p));
    }
    try testing.expectEqualStrings("application/wasm", contentType("sorz.wasm"));
    try testing.expectEqualStrings("text/html; charset=utf-8", contentType("index.html"));
    try testing.expectEqualStrings("application/octet-stream", contentType("x.bin"));
}
