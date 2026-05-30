const std = @import("std");
const client = @import("client.zig");
const json = @import("json.zig");

pub const ImageDetail = enum {
    auto,
    low,
    high,
};

pub const ImageUrl = struct {
    /// URL or data URL of the image.
    url: []const u8,
    /// Detail level for image understanding.
    detail: ?ImageDetail = null,

    /// Allocates a `data:<mime_type>;base64,...` URL for local image bytes.
    /// Caller owns the returned slice.
    pub fn dataUrlAlloc(allocator: std.mem.Allocator, mime_type: []const u8, bytes: []const u8) ![]u8 {
        const data_prefix = "data:";
        const base64_prefix = ";base64,";
        const prefix_len = data_prefix.len + mime_type.len + base64_prefix.len;
        const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
        const url = try allocator.alloc(u8, prefix_len + encoded_len);

        var offset: usize = 0;
        @memcpy(url[offset..][0..data_prefix.len], data_prefix);
        offset += data_prefix.len;
        @memcpy(url[offset..][0..mime_type.len], mime_type);
        offset += mime_type.len;
        @memcpy(url[offset..][0..base64_prefix.len], base64_prefix);
        offset += base64_prefix.len;

        _ = std.base64.standard.Encoder.encode(url[offset..], bytes);
        return url;
    }
};

pub const ChatContentPart = union(enum) {
    text: []const u8,
    image_url: ImageUrl,

    pub fn jsonStringify(self: ChatContentPart, writer: anytype) !void {
        try writer.beginObject();
        switch (self) {
            .text => |text| {
                try writer.objectField("type");
                try writer.write("text");
                try writer.objectField("text");
                try writer.write(text);
            },
            .image_url => |image| {
                try writer.objectField("type");
                try writer.write("image_url");
                try writer.objectField("image_url");
                try writer.write(image);
            },
        }
        try writer.endObject();
    }
};

pub const ChatMessageContent = union(enum) {
    text: []const u8,
    parts: []const ChatContentPart,

    pub fn jsonStringify(self: ChatMessageContent, writer: anytype) !void {
        switch (self) {
            .text => |text| try writer.write(text),
            .parts => |parts| try writer.write(parts),
        }
    }
};

pub const ChatMessage = struct {
    role: []const u8,
    content: ChatMessageContent,
};

/// Request for chat completions
pub const ChatCompletionsRequest = struct {
    /// Required: ID of the model to use
    model: []const u8,

    /// Required: A list of messages comprising the conversation so far.
    messages: []const ChatMessage,

    /// Optional: Whether to store the output of this chat completion request
    /// Defaults to false
    store: ?bool = null,

    /// Optional: Whether to stream the response as server-sent events.
    stream: ?bool = null,

    /// Optional: Constrains effort on reasoning for reasoning models (o1 and o3-mini models only)
    /// Supported values: "low", "medium", "high"
    /// Defaults to "medium" if left null,
    reasoning_effort: ?[]const u8 = null,

    // Optional: Set of key-value pairs for storing additional information
    // TODO: implement metadata parameter as StringHashMap
    // metadata: StringHashMap([]const u8),

    /// Optional: Number between -2.0 and 2.0
    /// Positive values penalize new tokens based on their existing frequency
    /// Defaults to 0.0 if left null.
    frequency_penalty: ?f32 = null,

    // Optional: Modify likelihood of specified tokens appearing in completion
    // TODO: implement logit_bias parameter as IntegerHashMap
    // logit_bias: IntegerHashMap(f32),

    /// Optional: Whether to return log probabilities of output tokens
    /// Defaults to false
    logprobs: ?bool = null,

    /// Optional: Number of most likely tokens to return at each position (0-20)
    /// Requires logprobs to be true
    top_logprobs: ?i32 = null,

    /// Deprecated: Use max_completion_tokens instead
    /// Optional: Maximum tokens to generate
    max_tokens: ?i32 = null,

    /// Optional: Upper bound for generated tokens including visible and reasoning tokens
    max_completion_tokens: ?i32 = null,

    /// Optional: Number of chat completion choices to generate
    /// Defaults to 1 if left null.
    n: ?i32 = null,

    /// Optional: Output types for model to generate (e.g. ["text"], ["text", "audio"])
    /// Defaults to ["text"]
    modalities: ?[][]const u8 = null,

    // Optional: Configuration for Predicted Output
    // TODO: implement prediction parameter as struct
    // prediction: PredictionConfig,

    // Optional: Parameters for audio output
    // TODO: implement audio parameter as struct
    // audio: AudioConfig,

    /// Optional: Number between -2.0 and 2.0
    /// Positive values penalize new tokens based on presence in text
    /// Defaults to 0.0 if left null
    presence_penalty: ?f32 = null,

    // Optional: Format specification for model output
    // TODO: implement response_format parameter as union
    // response_format: ResponseFormat,

    /// Optional: Seed for deterministic sampling
    seed: ?i64 = null,

    /// Optional: Latency tier for processing the request
    /// Values: "auto", "default"
    /// Defaults to "auto"
    service_tier: ?[]const u8 = null,

    /// Optional: Up to 4 sequences where API stops generating tokens
    /// An array of strings
    stop: ?[]const []const u8 = null,

    /// Optional: Temperature for sampling (0.0-2.0)
    /// Higher values increase randomness.
    /// Defaults to 1.0 if left null
    temperature: ?f32 = null,

    /// Optional: Alternative to temperature for nucleus sampling (0.0-1.0)
    /// Defaults to 1.0 if left null
    top_p: ?f32 = null,

    // Optional: List of tools (functions) the model may call
    // TODO: implement tools parameter as array of structs
    // tools: []Tool,

    // Optional: Controls which tool is called by the model
    // TODO: implement tool_choice parameter as union
    // tool_choice: ToolChoice,

    // Optional: Enable parallel function calling during tool use
    // Defaults to true
    // TODO: implement parallel_tool_calls
    // parallel_tool_calls: bool = true,

    /// Optional: Unique identifier for end-user
    user: ?[]const u8 = null,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    // refusal: ?[]const u8 = null,
    // function_call: ?[]const u8 = null,
};

/// A streamed chat completions payload
pub const ChatCompletionChunk = struct {
    id: []const u8,
    object: []const u8,
    created: f64,
    model: []const u8,
    service_tier: []const u8,
    system_fingerprint: []const u8,
    choices: []const struct {
        index: usize,
        delta: struct {
            content: []const u8 = "",
        },
        logprobs: ?[]const u8 = null,
        finish_reason: ?[]const u8 = null,
    },
};

/// A chat completions payload.
pub const ChatCompletion = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []struct {
        index: u64,
        message: Message,
        // logprobs: ?[]const u8 = null,
        finish_reason: []const u8,
    },
    usage: struct {
        prompt_tokens: u64,
        completion_tokens: u64,
        total_tokens: u64,
        prompt_tokens_details: ?struct {
            cached_tokens: ?u64 = null,
            audio_tokens: ?u64 = null,
        } = null,
        completion_tokens_details: ?struct {
            reasoning_tokens: ?u64 = null,
            audio_tokens: ?u64 = null,
            accepted_prediction_tokens: ?u64 = null,
            rejected_prediction_tokens: ?u64 = null,
        } = null,
    },
    service_tier: []const u8,
    system_fingerprint: ?[]const u8 = null,
    arena: json.Arena = .{},

    pub fn deinit(self: *const ChatCompletion) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

/// A struct that contains methods for creating chat completions
pub const Completions = struct {
    openai: *const client.OpenAI,

    /// Initializes a new Completions struct
    /// This should only be called once per OpenAI instance
    pub fn init(openai: *const client.OpenAI) Completions {
        return .{ .openai = openai };
    }

    pub fn deinit(_: *Completions) void {}

    /// Creates a chat completion request and returns a ChatCompletion
    /// The caller is also responsible for calling deinit() on the response to free all allocated memory.
    pub fn create(self: *Completions, request: ChatCompletionsRequest) !ChatCompletion {
        const allocator = self.openai.allocator;
        const body = try json.stringifyAlloc(allocator, request, .{
            .emit_null_optional_fields = false,
        });
        defer allocator.free(body);
        return self.openai.request(.{
            .method = .POST,
            .path = "/chat/completions",
            .json = body,
        }, ChatCompletion);
    }

    /// Creates a chat completion request and returns a `Stream(ChatCompletionChunk)`
    /// The caller is also responsible for calling deinit() on the stream to free all allocated memory.
    pub fn createStream(self: *const Completions, request: ChatCompletionsRequest) !client.Stream(ChatCompletionChunk) {
        const allocator = self.openai.allocator;

        var payload = request;
        payload.stream = true;

        const body = try json.stringifyAlloc(allocator, payload, .{
            .emit_null_optional_fields = false,
        });
        defer allocator.free(body);
        return self.openai.requestStream(.{
            .method = .POST,
            .path = "/chat/completions",
            .json = body,
        }, ChatCompletionChunk);
    }
};

test "chat message serializes text content as a string" {
    const allocator = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{
            .role = "user",
            .content = .{ .text = "Hello" },
        },
    };
    const request = ChatCompletionsRequest{
        .model = "gpt-4o-mini",
        .messages = &messages,
    };

    const body = try json.stringifyAlloc(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}]}
    , body);
}

test "chat message serializes image content parts" {
    const allocator = std.testing.allocator;
    const parts = [_]ChatContentPart{
        .{ .text = "What is in this image?" },
        .{ .image_url = .{
            .url = "https://example.com/image.png",
            .detail = .high,
        } },
    };
    const messages = [_]ChatMessage{
        .{
            .role = "user",
            .content = .{ .parts = &parts },
        },
    };
    const request = ChatCompletionsRequest{
        .model = "gpt-4o-mini",
        .messages = &messages,
    };

    const body = try json.stringifyAlloc(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"gpt-4o-mini","messages":[{"role":"user","content":[{"type":"text","text":"What is in this image?"},{"type":"image_url","image_url":{"url":"https://example.com/image.png","detail":"high"}}]}]}
    , body);
}

test "image URL helper builds data URL" {
    const allocator = std.testing.allocator;
    const url = try ImageUrl.dataUrlAlloc(allocator, "image/png", "hello");
    defer allocator.free(url);

    try std.testing.expectEqualStrings("data:image/png;base64,aGVsbG8=", url);
}
