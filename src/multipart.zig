//! The multipart/form-data encoder shared by every multipart request in the Zig
//! SDK: the file upload, the OpenAI transcription, and the OpenAI image edit
//! (BUG-097). Each caller writes its parts in a fixed order and supplies a fixed
//! boundary, so the encoded body is reproducible and the request-wire drivers
//! can decode it back to the canonical descriptor.
//!
//! Filename escaping (HANDOFF-036 A2): names and filenames are escaped as Go's
//! stdlib `escapeQuotes` does, so a quote or CRLF cannot corrupt a part header.

const std = @import("std");

/// Accumulates one multipart body. Write fields and files in wire order, then
/// call `finish` for the bytes with the closing delimiter.
pub const Writer = struct {
    boundary: []const u8,
    buf: std.ArrayList(u8) = .empty,

    /// Append one text field: `--boundary\r\nContent-Disposition: form-data;
    /// name="<name>"\r\n\r\n<value>\r\n`.
    pub fn field(self: *Writer, arena: std.mem.Allocator, name: []const u8, value: []const u8) std.mem.Allocator.Error!void {
        try self.delimiter(arena);
        try self.buf.appendSlice(arena, "Content-Disposition: form-data; name=\"");
        try appendEscaped(arena, &self.buf, name);
        try self.buf.appendSlice(arena, "\"\r\n\r\n");
        try self.buf.appendSlice(arena, value);
        try self.buf.appendSlice(arena, "\r\n");
    }

    /// Append one file part with its filename, Content-Type and raw bytes.
    pub fn file(
        self: *Writer,
        arena: std.mem.Allocator,
        name: []const u8,
        filename: []const u8,
        content_type: []const u8,
        bytes: []const u8,
    ) std.mem.Allocator.Error!void {
        try self.delimiter(arena);
        try self.buf.appendSlice(arena, "Content-Disposition: form-data; name=\"");
        try appendEscaped(arena, &self.buf, name);
        try self.buf.appendSlice(arena, "\"; filename=\"");
        try appendEscaped(arena, &self.buf, filename);
        try self.buf.appendSlice(arena, "\"\r\nContent-Type: ");
        try self.buf.appendSlice(arena, content_type);
        try self.buf.appendSlice(arena, "\r\n\r\n");
        try self.buf.appendSlice(arena, bytes);
        try self.buf.appendSlice(arena, "\r\n");
    }

    /// Append the closing delimiter and return the encoded body.
    pub fn finish(self: *Writer, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        try self.buf.appendSlice(arena, "--");
        try self.buf.appendSlice(arena, self.boundary);
        try self.buf.appendSlice(arena, "--\r\n");
        return self.buf.toOwnedSlice(arena);
    }

    fn delimiter(self: *Writer, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.buf.appendSlice(arena, "--");
        try self.buf.appendSlice(arena, self.boundary);
        try self.buf.appendSlice(arena, "\r\n");
    }
};

/// Escape a value destined for a quoted-string in a part header, matching Go's
/// stdlib `escapeQuotes`: backslash and double-quote are backslash-escaped, and
/// CR/LF are dropped so a crafted filename cannot inject a header line.
fn appendEscaped(arena: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    for (s) |ch| switch (ch) {
        '\\', '"' => {
            try buf.append(arena, '\\');
            try buf.append(arena, ch);
        },
        '\r', '\n' => {},
        else => try buf.append(arena, ch),
    };
}
