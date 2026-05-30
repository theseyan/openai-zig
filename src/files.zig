const std = @import("std");
const client = @import("client.zig");
const json = @import("json.zig");
const multipart = @import("multipart.zig");

pub const FilePurpose = enum {
    assistants,
    batch,
    @"fine-tune",
    vision,
    user_data,
    evals,
};

pub const FileUpload = struct {
    filename: []const u8,
    content: []const u8,
    content_type: []const u8 = "application/octet-stream",
};

pub const FileExpiresAfter = struct {
    anchor: []const u8 = "created_at",
    seconds: u64,
};

pub const FileCreateRequest = struct {
    file: FileUpload,
    purpose: FilePurpose,
    expires_after: ?FileExpiresAfter = null,
};

pub const FileListOrder = enum {
    asc,
    desc,
};

pub const FileListRequest = struct {
    after: ?[]const u8 = null,
    limit: ?u16 = null,
    order: ?FileListOrder = null,
    purpose: ?[]const u8 = null,
};

pub const FileObject = struct {
    id: []const u8,
    bytes: u64,
    created_at: i64,
    filename: []const u8,
    object: []const u8,
    purpose: []const u8,
    status: ?[]const u8 = null,
    expires_at: ?i64 = null,
    status_details: ?[]const u8 = null,
    arena: json.Arena = .{},

    pub fn deinit(self: *const FileObject) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

pub const FileListResponse = struct {
    object: []const u8,
    data: []const FileObject,
    has_more: ?bool = null,
    first_id: ?[]const u8 = null,
    last_id: ?[]const u8 = null,
    arena: json.Arena = .{},

    pub fn deinit(self: *const FileListResponse) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

pub const FileDeleted = struct {
    id: []const u8,
    deleted: bool,
    object: []const u8,
    arena: json.Arena = .{},

    pub fn deinit(self: *const FileDeleted) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

pub const Files = struct {
    openai: *const client.OpenAI,

    pub fn init(openai: *const client.OpenAI) Files {
        return .{ .openai = openai };
    }

    pub fn deinit(_: *Files) void {}

    pub fn list(self: *const Files, request: FileListRequest) !FileListResponse {
        const path = try buildListPath(self.openai.allocator, request);
        defer self.openai.allocator.free(path);
        return self.openai.request(.{
            .method = .GET,
            .path = path,
        }, FileListResponse);
    }

    pub fn create(self: *const Files, request: FileCreateRequest) !FileObject {
        const allocator = self.openai.allocator;
        var boundary_buffer: [64]u8 = undefined;
        const boundary = try multipart.makeBoundary(&boundary_buffer, self.openai.io);
        const content_type = try multipart.contentType(allocator, boundary);
        defer allocator.free(content_type);

        const body = try buildCreateBody(allocator, boundary, request);
        defer allocator.free(body);

        return self.openai.requestMultipart(.{
            .path = "/files",
            .body = body,
            .content_type = content_type,
        }, FileObject);
    }

    pub fn retrieve(self: *const Files, file_id: []const u8) !FileObject {
        const path = try buildFilePath(self.openai.allocator, file_id, "");
        defer self.openai.allocator.free(path);
        return self.openai.request(.{
            .method = .GET,
            .path = path,
        }, FileObject);
    }

    pub fn delete(self: *const Files, file_id: []const u8) !FileDeleted {
        const path = try buildFilePath(self.openai.allocator, file_id, "");
        defer self.openai.allocator.free(path);
        return self.openai.request(.{
            .method = .DELETE,
            .path = path,
        }, FileDeleted);
    }

    /// Returns the raw file content. Caller owns the returned bytes and must free them
    /// with the client's allocator.
    pub fn content(self: *const Files, file_id: []const u8, max_bytes: usize) ![]u8 {
        const path = try buildFilePath(self.openai.allocator, file_id, "/content");
        defer self.openai.allocator.free(path);
        return self.openai.requestRaw(.{
            .method = .GET,
            .path = path,
        }, max_bytes);
    }
};

fn buildListPath(allocator: std.mem.Allocator, request: FileListRequest) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("/files");

    var has_query = false;
    if (request.after) |after| try appendQueryParam(&writer.writer, &has_query, "after", after);
    if (request.limit) |limit| {
        var buffer: [16]u8 = undefined;
        try appendQueryParam(&writer.writer, &has_query, "limit", try std.fmt.bufPrint(&buffer, "{d}", .{limit}));
    }
    if (request.order) |order| try appendQueryParam(&writer.writer, &has_query, "order", @tagName(order));
    if (request.purpose) |purpose| try appendQueryParam(&writer.writer, &has_query, "purpose", purpose);

    return writer.toOwnedSlice();
}

fn buildFilePath(allocator: std.mem.Allocator, file_id: []const u8, suffix: []const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("/files/");
    try writePercentEncoded(&writer.writer, file_id);
    try writer.writer.writeAll(suffix);
    return writer.toOwnedSlice();
}

fn appendQueryParam(writer: *std.Io.Writer, has_query: *bool, name: []const u8, value: []const u8) !void {
    try writer.writeByte(if (has_query.*) '&' else '?');
    has_query.* = true;
    try writePercentEncoded(writer, name);
    try writer.writeByte('=');
    try writePercentEncoded(writer, value);
}

fn writePercentEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(byte),
            else => {
                try writer.writeByte('%');
                try writer.writeByte(hex[byte >> 4]);
                try writer.writeByte(hex[byte & 0x0f]);
            },
        }
    }
}

fn buildCreateBody(allocator: std.mem.Allocator, boundary: []const u8, request: FileCreateRequest) ![]u8 {
    var fields = std.ArrayList(multipart.Field).empty;
    defer fields.deinit(allocator);

    try fields.append(allocator, .{
        .name = "purpose",
        .value = @tagName(request.purpose),
    });

    var seconds_buffer: [32]u8 = undefined;
    if (request.expires_after) |expires_after| {
        try fields.append(allocator, .{
            .name = "expires_after[anchor]",
            .value = expires_after.anchor,
        });
        try fields.append(allocator, .{
            .name = "expires_after[seconds]",
            .value = try std.fmt.bufPrint(&seconds_buffer, "{d}", .{expires_after.seconds}),
        });
    }

    const file_parts = [_]multipart.File{
        .{
            .field_name = "file",
            .filename = request.file.filename,
            .content = request.file.content,
            .content_type = request.file.content_type,
        },
    };

    return multipart.build(allocator, boundary, fields.items, &file_parts);
}

test "build file create multipart body" {
    const allocator = std.testing.allocator;
    const body = try buildCreateBody(allocator, "test-boundary", .{
        .file = .{
            .filename = "README.md",
            .content = "Example data",
            .content_type = "text/markdown",
        },
        .purpose = .assistants,
        .expires_after = .{ .seconds = 3600 },
    });
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

test "build files list path" {
    const allocator = std.testing.allocator;
    const path = try buildListPath(allocator, .{
        .after = "file/123?",
        .limit = 20,
        .order = .desc,
        .purpose = "fine-tune",
    });
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/files?after=file%2F123%3F&limit=20&order=desc&purpose=fine-tune", path);
}

test "build files list path without params" {
    const allocator = std.testing.allocator;
    const path = try buildListPath(allocator, .{});
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/files", path);
}

test "build file paths escape file ids" {
    const allocator = std.testing.allocator;
    const path = try buildFilePath(allocator, "file/abc?#%", "/content");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/files/file%2Fabc%3F%23%25/content", path);
}

test "parse files list response" {
    const allocator = std.testing.allocator;
    const response = try json.deserializeStructWithArena(FileListResponse, allocator,
        \\{
        \\  "object": "list",
        \\  "data": [{
        \\    "id": "file-abc",
        \\    "bytes": 42,
        \\    "created_at": 1710000000,
        \\    "filename": "training.jsonl",
        \\    "object": "file",
        \\    "purpose": "fine-tune",
        \\    "status": "processed"
        \\  }],
        \\  "has_more": false,
        \\  "first_id": "file-abc",
        \\  "last_id": "file-abc"
        \\}
    );
    defer response.deinit();

    try std.testing.expectEqualStrings("list", response.object);
    try std.testing.expectEqual(@as(usize, 1), response.data.len);
    try std.testing.expectEqualStrings("file-abc", response.data[0].id);
    try std.testing.expectEqual(false, response.has_more.?);
}

test "parse file deleted response" {
    const allocator = std.testing.allocator;
    const response = try json.deserializeStructWithArena(FileDeleted, allocator,
        \\{
        \\  "id": "file-abc",
        \\  "object": "file",
        \\  "deleted": true
        \\}
    );
    defer response.deinit();

    try std.testing.expectEqualStrings("file-abc", response.id);
    try std.testing.expect(response.deleted);
    try std.testing.expectEqualStrings("file", response.object);
}
