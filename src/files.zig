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

pub const Files = struct {
    openai: *const client.OpenAI,

    pub fn init(openai: *const client.OpenAI) Files {
        return .{ .openai = openai };
    }

    pub fn deinit(_: *Files) void {}

    pub fn create(self: *const Files, request: FileCreateRequest) !FileObject {
        const allocator = self.openai.allocator;
        var boundary_buffer: [64]u8 = undefined;
        const boundary = try multipart.makeBoundary(&boundary_buffer, self.openai.io);
        const content_type = try multipart.contentTypeAlloc(allocator, boundary);
        defer allocator.free(content_type);

        const body = try buildCreateBodyAlloc(allocator, boundary, request);
        defer allocator.free(body);

        return self.openai.requestMultipart(.{
            .path = "/files",
            .body = body,
            .content_type = content_type,
        }, FileObject);
    }
};

fn buildCreateBodyAlloc(allocator: std.mem.Allocator, boundary: []const u8, request: FileCreateRequest) ![]u8 {
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

    return multipart.buildAlloc(allocator, boundary, fields.items, &file_parts);
}

test "build file create multipart body" {
    const allocator = std.testing.allocator;
    const body = try buildCreateBodyAlloc(allocator, "test-boundary", .{
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
