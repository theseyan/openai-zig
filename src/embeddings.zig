const std = @import("std");
const client = @import("client.zig");
const json = @import("json.zig");

/// Request payload for `embeddings.create`
pub const EmbeddingsRequest = struct {
    model: []const u8,
    input: []const []const u8,
    encoding_format: ?[]const u8 = null,
    dimensions: ?usize = null,
    user: ?[]const u8 = null,
};

const EmbeddingObjectResponse = struct {
    object: []const u8,
    embedding: []f64,
    index: usize,
    arena: json.Arena = .{},

    pub fn deinit(self: *const EmbeddingObjectResponse) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

/// Usage object for `EmbeddingsResponse.usage`
const EmbeddingsUsage = struct {
    prompt_tokens: usize,
    total_tokens: usize,
};

const EmbeddingObject = struct {
    object: []const u8,
    embedding: []f64,
    index: usize,
};

/// The embeddings response object
/// The user is responsible for calling the deinit method on this object.
const EmbeddingResponse = struct {
    object: []const u8,
    data: []const EmbeddingObject,
    model: []const u8,
    usage: EmbeddingsUsage,
    arena: json.Arena = .{},

    /// This will deinitialize all memory created for this response
    pub fn deinit(self: *const EmbeddingResponse) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

/// Module for `/embeddings` endpoints
pub const Embeddings = struct {
    openai: *const client.OpenAI,

    pub fn init(openai: *const client.OpenAI) Embeddings {
        return .{ .openai = openai };
    }

    /// Sends `POST` request to `/embeddings` with the given `EmbeddingsRequest`.
    /// The caller is also responsible for calling deinit() on the response to free all allocated memory.
    /// Returns a `client.Resource` wrapper containing an `EmbeddingsResponse`.
    pub fn create(self: *Embeddings, request: EmbeddingsRequest) !EmbeddingResponse {
        const body = try json.stringify(self.openai.allocator, request, .{
            .emit_null_optional_fields = false,
        });
        defer self.openai.allocator.free(body);
        return self.openai.request(.{
            .method = .POST,
            .path = "/embeddings",
            .json = body,
        }, EmbeddingResponse);
    }

    pub fn deinit(_: *Embeddings) void {}
};
