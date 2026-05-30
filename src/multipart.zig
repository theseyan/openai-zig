const std = @import("std");

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const File = struct {
    field_name: []const u8,
    filename: []const u8,
    content: []const u8,
    content_type: []const u8 = "application/octet-stream",
};

pub const MultipartError = error{
    InvalidHeaderValue,
};

pub fn makeBoundary(buffer: []u8, io: std.Io) ![]const u8 {
    const prefix = "openai-zig-";
    const random_len = 16;
    if (buffer.len < prefix.len + random_len * 2) return error.NoSpaceLeft;

    var random: [random_len]u8 = undefined;
    io.random(&random);

    @memcpy(buffer[0..prefix.len], prefix);
    const hex = std.fmt.bytesToHex(random, .lower);
    @memcpy(buffer[prefix.len..][0..hex.len], &hex);
    return buffer[0 .. prefix.len + random_len * 2];
}

pub fn contentType(allocator: std.mem.Allocator, boundary: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
}

pub fn build(allocator: std.mem.Allocator, boundary: []const u8, fields: []const Field, files: []const File) ![]u8 {
    var body = std.Io.Writer.Allocating.init(allocator);
    errdefer body.deinit();

    for (fields) |field| {
        try writePartBoundary(&body.writer, boundary);
        try writeDisposition(&body.writer, field.name, null);
        try body.writer.writeAll("\r\n");
        try body.writer.writeAll(field.value);
        try body.writer.writeAll("\r\n");
    }

    for (files) |file| {
        try writePartBoundary(&body.writer, boundary);
        try writeDisposition(&body.writer, file.field_name, file.filename);
        try body.writer.writeAll("Content-Type: ");
        try writeHeaderValue(&body.writer, file.content_type);
        try body.writer.writeAll("\r\n\r\n");
        try body.writer.writeAll(file.content);
        try body.writer.writeAll("\r\n");
    }

    try body.writer.print("--{s}--\r\n", .{boundary});
    return body.toOwnedSlice();
}

fn writePartBoundary(writer: *std.Io.Writer, boundary: []const u8) !void {
    try writer.print("--{s}\r\n", .{boundary});
}

fn writeDisposition(writer: *std.Io.Writer, name: []const u8, filename: ?[]const u8) !void {
    try writer.writeAll("Content-Disposition: form-data; name=\"");
    try writeQuoted(writer, name);
    try writer.writeByte('"');
    if (filename) |value| {
        try writer.writeAll("; filename=\"");
        try writeQuoted(writer, value);
        try writer.writeByte('"');
    }
    try writer.writeAll("\r\n");
}

fn writeHeaderValue(writer: *std.Io.Writer, value: []const u8) !void {
    try rejectHeaderInjection(value);
    try writer.writeAll(value);
}

fn writeQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try rejectHeaderInjection(value);
    for (value) |byte| {
        switch (byte) {
            '\\', '"' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            else => try writer.writeByte(byte),
        }
    }
}

fn rejectHeaderInjection(value: []const u8) MultipartError!void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return MultipartError.InvalidHeaderValue;
}

test "build multipart body" {
    const allocator = std.testing.allocator;
    const fields = [_]Field{
        .{ .name = "purpose", .value = "assistants" },
        .{ .name = "expires_after[anchor]", .value = "created_at" },
        .{ .name = "expires_after[seconds]", .value = "3600" },
    };
    const files = [_]File{
        .{
            .field_name = "file",
            .filename = "README.md",
            .content = "Example data",
            .content_type = "text/markdown",
        },
    };

    const body = try build(allocator, "test-boundary", &fields, &files);
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        "--test-boundary\r\n" ++
            "Content-Disposition: form-data; name=\"purpose\"\r\n" ++
            "\r\n" ++
            "assistants\r\n" ++
            "--test-boundary\r\n" ++
            "Content-Disposition: form-data; name=\"expires_after[anchor]\"\r\n" ++
            "\r\n" ++
            "created_at\r\n" ++
            "--test-boundary\r\n" ++
            "Content-Disposition: form-data; name=\"expires_after[seconds]\"\r\n" ++
            "\r\n" ++
            "3600\r\n" ++
            "--test-boundary\r\n" ++
            "Content-Disposition: form-data; name=\"file\"; filename=\"README.md\"\r\n" ++
            "Content-Type: text/markdown\r\n" ++
            "\r\n" ++
            "Example data\r\n" ++
            "--test-boundary--\r\n",
        body,
    );
}

test "reject header injection" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(MultipartError.InvalidHeaderValue, writeQuoted(&writer, "bad\r\nname"));
}
