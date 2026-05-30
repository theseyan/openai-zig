const std = @import("std");
const client = @import("client.zig");
const json = @import("json.zig");
const OpenAI = client.OpenAI;

pub const ListModelResponse = struct {
    object: []const u8,
    data: []const Object,
    arena: json.Arena = .{},

    pub fn deinit(self: *const ListModelResponse) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};
pub const Object = struct { id: []const u8, object: []const u8, created: u64, owned_by: []const u8 };

/// Response payload. The user is responsible for calling deinit() to free all memory for this request.
pub const ObjectResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    owned_by: []const u8,
    arena: json.Arena = .{},

    pub fn deinit(self: *const ObjectResponse) void {
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
    /// Caller is responsible for calling `deinit` on the returned `ObjectResponse` object to clean up all memory.
    pub fn retrieve(self: *const Models, id: []const u8) !ObjectResponse {
        const path = try std.fmt.allocPrint(self.client.allocator, "/models/{s}", .{id});
        defer self.client.allocator.free(path);
        return self.client.request(.{ .method = .GET, .path = path }, ObjectResponse);
    }
};
