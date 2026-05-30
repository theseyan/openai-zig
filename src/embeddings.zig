const std = @import("std");
const client = @import("client.zig");
const json = @import("json.zig");

/// Request payload for `embeddings.create`
pub const EmbeddingsRequest = struct {
    model: []const u8,
    input: EmbeddingInput,
    encoding_format: ?[]const u8 = null,
    dimensions: ?usize = null,
    user: ?[]const u8 = null,
};

pub const EmbeddingInput = union(enum) {
    text: []const u8,
    texts: []const []const u8,
    tokens: []const i64,
    token_batches: []const []const i64,

    pub fn jsonStringify(self: EmbeddingInput, writer: anytype) !void {
        switch (self) {
            .text => |text| try writer.write(text),
            .texts => |texts| try writer.write(texts),
            .tokens => |tokens| try writer.write(tokens),
            .token_batches => |token_batches| try writer.write(token_batches),
        }
    }
};

/// Usage object for `EmbeddingsResponse.usage`
pub const EmbeddingsUsage = struct {
    prompt_tokens: usize,
    total_tokens: usize,
};

pub const EmbeddingVector = union(enum) {
    float: []f64,
    base64: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !EmbeddingVector {
        return switch (try source.peekNextTokenType()) {
            .array_begin => .{ .float = try std.json.innerParse([]f64, allocator, source, options) },
            .string => .{ .base64 = try std.json.innerParse([]const u8, allocator, source, options) },
            else => error.UnexpectedToken,
        };
    }
};

pub const EmbeddingObject = struct {
    object: []const u8,
    embedding: EmbeddingVector,
    index: usize,
};

/// The embeddings response object
/// The user is responsible for calling the deinit method on this object.
pub const EmbeddingsResponse = struct {
    object: []const u8,
    data: []const EmbeddingObject,
    model: []const u8,
    usage: EmbeddingsUsage,
    arena: json.Arena = .{},

    /// This will deinitialize all memory created for this response
    pub fn deinit(self: *const EmbeddingsResponse) void {
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
    pub fn create(self: *Embeddings, request: EmbeddingsRequest) !EmbeddingsResponse {
        const body = try json.stringify(self.openai.allocator, request, .{
            .emit_null_optional_fields = false,
        });
        defer self.openai.allocator.free(body);
        return self.openai.request(.{
            .method = .POST,
            .path = "/embeddings",
            .json = body,
        }, EmbeddingsResponse);
    }

    pub fn deinit(_: *Embeddings) void {}
};

test "embedding request serializes input variants" {
    const allocator = std.testing.allocator;
    const token_batches = [_][]const i64{
        &.{ 1, 2, 3 },
        &.{ 4, 5 },
    };
    const request = EmbeddingsRequest{
        .model = "text-embedding-3-small",
        .input = .{ .token_batches = &token_batches },
        .encoding_format = "base64",
    };

    const body = try json.stringify(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"text-embedding-3-small","input":[[1,2,3],[4,5]],"encoding_format":"base64"}
    , body);
}

test "embedding response parses float and base64 embeddings" {
    const allocator = std.testing.allocator;
    const response = try json.deserializeStructWithArena(EmbeddingsResponse, allocator,
        \\{
        \\  "object": "list",
        \\  "data": [
        \\    {
        \\      "object": "embedding",
        \\      "embedding": [0.1, 0.2],
        \\      "index": 0
        \\    },
        \\    {
        \\      "object": "embedding",
        \\      "embedding": "AAAA",
        \\      "index": 1
        \\    }
        \\  ],
        \\  "model": "text-embedding-3-small",
        \\  "usage": {
        \\    "prompt_tokens": 4,
        \\    "total_tokens": 4
        \\  }
        \\}
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.data.len);
    try std.testing.expectEqual(@as(f64, 0.1), response.data[0].embedding.float[0]);
    try std.testing.expectEqualStrings("AAAA", response.data[1].embedding.base64);
}
