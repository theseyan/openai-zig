const std = @import("std");
const client = @import("client.zig");
const json = @import("json.zig");
const OpenAI = client.OpenAI;

pub const ListModelResponse = struct {
    object: []const u8,
    data: []const ModelObject,
    arena: json.Arena = .{},

    pub fn deinit(self: *const ListModelResponse) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};
pub const ModelObject = struct { id: []const u8, object: []const u8, created: u64, owned_by: []const u8 };

/// Response payload. The user is responsible for calling deinit() to free all memory for this request.
pub const ModelResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    owned_by: []const u8,
    arena: json.Arena = .{},

    pub fn deinit(self: *const ModelResponse) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

pub const ModelDeleted = struct {
    id: []const u8,
    deleted: bool,
    object: []const u8,
    arena: json.Arena = .{},

    pub fn deinit(self: *const ModelDeleted) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

/// Struct containing all API calls for the /models routes.
pub const Models = struct {
    client: *const OpenAI,

    pub fn init(openai: *const OpenAI) Models {
        return Models{
            .client = openai,
        };
    }

    pub fn deinit(_: *Models) void {}

    /// Lists available models.
    /// Caller is responsible for calling `deinit` on the returned `ListModelResponse` object to clean up all memory.
    pub fn list(self: *const Models) !ListModelResponse {
        return self.client.request(.{ .method = .GET, .path = "/models" }, ListModelResponse);
    }

    /// Retrieves model information for provided model ID (e.g. "gpt-4o").
    /// Caller is responsible for calling `deinit` on the returned `ModelResponse` object to clean up all memory.
    pub fn retrieve(self: *const Models, id: []const u8) !ModelResponse {
        const path = try buildModelPath(self.client.allocator, id);
        defer self.client.allocator.free(path);
        return self.client.request(.{ .method = .GET, .path = path }, ModelResponse);
    }

    /// Deletes a fine-tuned model. Requires Owner role in the organization.
    pub fn delete(self: *const Models, id: []const u8) !ModelDeleted {
        const path = try buildModelPath(self.client.allocator, id);
        defer self.client.allocator.free(path);
        return self.client.request(.{ .method = .DELETE, .path = path }, ModelDeleted);
    }
};

fn buildModelPath(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("/models/");
    try writePercentEncoded(&writer.writer, id);
    return writer.toOwnedSlice();
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

test "build model path escapes ids" {
    const allocator = std.testing.allocator;
    const path = try buildModelPath(allocator, "ft:model/abc?#%");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/models/ft%3Amodel%2Fabc%3F%23%25", path);
}

test "parse model deleted response" {
    const allocator = std.testing.allocator;
    const deleted = try json.deserializeStructWithArena(ModelDeleted, allocator,
        \\{
        \\  "id": "ft:gpt-4o-mini:org:custom:abc",
        \\  "deleted": true,
        \\  "object": "model"
        \\}
    );
    defer deleted.deinit();

    try std.testing.expectEqualStrings("ft:gpt-4o-mini:org:custom:abc", deleted.id);
    try std.testing.expect(deleted.deleted);
}
