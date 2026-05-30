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
    pub fn dataUrl(allocator: std.mem.Allocator, mime_type: []const u8, bytes: []const u8) ![]u8 {
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

pub const ChatToolFunction = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
    strict: ?bool = null,
};

pub const ChatCustomTool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    format: ?std.json.Value = null,
};

pub const ChatTool = union(enum) {
    function: ChatToolFunction,
    custom: ChatCustomTool,

    pub fn jsonStringify(self: ChatTool, writer: anytype) !void {
        try writer.beginObject();
        switch (self) {
            .function => |function| {
                try writer.objectField("type");
                try writer.write("function");
                try writer.objectField("function");
                try writer.write(function);
            },
            .custom => |custom| {
                try writer.objectField("type");
                try writer.write("custom");
                try writer.objectField("custom");
                try writer.write(custom);
            },
        }
        try writer.endObject();
    }
};

pub const ChatAllowedTools = struct {
    mode: []const u8,
    tools: []const std.json.Value,
};

pub const ChatToolChoice = union(enum) {
    none,
    auto,
    required,
    function: []const u8,
    custom: []const u8,
    allowed_tools: ChatAllowedTools,

    pub fn jsonStringify(self: ChatToolChoice, writer: anytype) !void {
        switch (self) {
            .none => try writer.write("none"),
            .auto => try writer.write("auto"),
            .required => try writer.write("required"),
            .function => |name| {
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("function");
                try writer.objectField("function");
                try writer.beginObject();
                try writer.objectField("name");
                try writer.write(name);
                try writer.endObject();
                try writer.endObject();
            },
            .custom => |name| {
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("custom");
                try writer.objectField("custom");
                try writer.beginObject();
                try writer.objectField("name");
                try writer.write(name);
                try writer.endObject();
                try writer.endObject();
            },
            .allowed_tools => |allowed_tools| {
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("allowed_tools");
                try writer.objectField("allowed_tools");
                try writer.write(allowed_tools);
                try writer.endObject();
            },
        }
    }
};

pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolCallCustom = struct {
    name: []const u8,
    input: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: ?ToolCallFunction = null,
    custom: ?ToolCallCustom = null,

    pub fn jsonStringify(self: ToolCall, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(self.id);
        try writer.objectField("type");
        try writer.write(if (self.custom != null and self.function == null) "custom" else self.type);
        if (self.function) |function| {
            try writer.objectField("function");
            try writer.write(function);
        }
        if (self.custom) |custom| {
            try writer.objectField("custom");
            try writer.write(custom);
        }
        try writer.endObject();
    }
};

pub const ToolCallDelta = struct {
    index: usize,
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?struct {
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    } = null,
    custom: ?struct {
        name: ?[]const u8 = null,
        input: ?[]const u8 = null,
    } = null,
};

pub const ChatMessage = struct {
    role: []const u8,
    content: ?ChatMessageContent = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
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

    /// Optional: List of tools the model may call.
    tools: ?[]const ChatTool = null,

    /// Optional: Controls which tool is called by the model.
    tool_choice: ?ChatToolChoice = null,

    /// Optional: Enable parallel function calling during tool use.
    /// Defaults to true if left null.
    parallel_tool_calls: ?bool = null,

    /// Optional: Unique identifier for end-user
    user: ?[]const u8 = null,
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    // refusal: ?[]const u8 = null,
};

/// A streamed chat completions payload
pub const ChatCompletionChunk = struct {
    id: []const u8,
    object: []const u8,
    created: f64,
    model: []const u8,
    service_tier: ?[]const u8 = null,
    system_fingerprint: ?[]const u8 = null,
    choices: []const struct {
        index: usize,
        delta: struct {
            role: ?[]const u8 = null,
            content: ?[]const u8 = null,
            tool_calls: ?[]const ToolCallDelta = null,
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
    service_tier: ?[]const u8 = null,
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
        const body = try json.stringify(allocator, request, .{
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

        const body = try json.stringify(allocator, payload, .{
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

    const body = try json.stringify(allocator, request, .{
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

    const body = try json.stringify(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"gpt-4o-mini","messages":[{"role":"user","content":[{"type":"text","text":"What is in this image?"},{"type":"image_url","image_url":{"url":"https://example.com/image.png","detail":"high"}}]}]}
    , body);
}

test "image URL helper builds data URL" {
    const allocator = std.testing.allocator;
    const url = try ImageUrl.dataUrl(allocator, "image/png", "hello");
    defer allocator.free(url);

    try std.testing.expectEqualStrings("data:image/png;base64,aGVsbG8=", url);
}

test "chat request serializes tools and function tool choice" {
    const allocator = std.testing.allocator;
    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();

    const parameters = try std.json.parseFromSliceLeaky(
        std.json.Value,
        schema_arena.allocator(),
        \\{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]}
    ,
        .{},
    );
    const tools = [_]ChatTool{
        .{
            .function = .{
                .name = "get_weather",
                .description = "Get weather for a location",
                .parameters = parameters,
            },
        },
    };
    const messages = [_]ChatMessage{
        .{
            .role = "user",
            .content = .{ .text = "Weather in Paris?" },
        },
    };
    const request = ChatCompletionsRequest{
        .model = "gpt-4o-mini",
        .messages = &messages,
        .tools = &tools,
        .tool_choice = .{ .function = "get_weather" },
        .parallel_tool_calls = true,
    };

    const body = try json.stringify(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Weather in Paris?"}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a location","parameters":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]}}}],"tool_choice":{"type":"function","function":{"name":"get_weather"}},"parallel_tool_calls":true}
    , body);
}

test "tool choice serializes string choices" {
    const allocator = std.testing.allocator;
    const choices = [_]ChatToolChoice{ .auto, .none, .required };
    const expected = [_][]const u8{ "\"auto\"", "\"none\"", "\"required\"" };

    for (choices, expected) |choice, value| {
        const body = try json.stringify(allocator, choice, .{});
        defer allocator.free(body);
        try std.testing.expectEqualStrings(value, body);
    }
}

test "chat request serializes custom tools and allowed tool choice" {
    const allocator = std.testing.allocator;
    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();

    const format = try std.json.parseFromSliceLeaky(
        std.json.Value,
        schema_arena.allocator(),
        \\{"type":"grammar","grammar":{"definition":"start: /[a-z]+/","syntax":"lark"}}
    ,
        .{},
    );
    const allowed_tool = try std.json.parseFromSliceLeaky(
        std.json.Value,
        schema_arena.allocator(),
        \\{"type":"custom","custom":{"name":"grammar_tool"}}
    ,
        .{},
    );
    const tools = [_]ChatTool{
        .{ .custom = .{
            .name = "grammar_tool",
            .description = "Parse constrained input",
            .format = format,
        } },
    };
    const allowed_tools = [_]std.json.Value{allowed_tool};
    const messages = [_]ChatMessage{
        .{
            .role = "user",
            .content = .{ .text = "Parse abc" },
        },
    };
    const request = ChatCompletionsRequest{
        .model = "gpt-4o-mini",
        .messages = &messages,
        .tools = &tools,
        .tool_choice = .{ .allowed_tools = .{
            .mode = "required",
            .tools = &allowed_tools,
        } },
    };

    const body = try json.stringify(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Parse abc"}],"tools":[{"type":"custom","custom":{"name":"grammar_tool","description":"Parse constrained input","format":{"type":"grammar","grammar":{"definition":"start: /[a-z]+/","syntax":"lark"}}}}],"tool_choice":{"type":"allowed_tools","allowed_tools":{"mode":"required","tools":[{"type":"custom","custom":{"name":"grammar_tool"}}]}}}
    , body);
}

test "tool choice serializes named custom tool" {
    const allocator = std.testing.allocator;
    const body = try json.stringify(allocator, ChatToolChoice{ .custom = "grammar_tool" }, .{});
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"type":"custom","custom":{"name":"grammar_tool"}}
    , body);
}

test "chat messages serialize assistant tool calls and tool results" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]ToolCall{
        .{
            .id = "call_123",
            .function = .{
                .name = "get_weather",
                .arguments = "{\"location\":\"Paris\"}",
            },
        },
    };
    const messages = [_]ChatMessage{
        .{
            .role = "assistant",
            .tool_calls = &tool_calls,
        },
        .{
            .role = "tool",
            .content = .{ .text = "{\"temperature\":\"18C\"}" },
            .tool_call_id = "call_123",
        },
    };
    const request = ChatCompletionsRequest{
        .model = "gpt-4o-mini",
        .messages = &messages,
    };

    const body = try json.stringify(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"gpt-4o-mini","messages":[{"role":"assistant","tool_calls":[{"id":"call_123","type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"Paris\"}"}}]},{"role":"tool","content":"{\"temperature\":\"18C\"}","tool_call_id":"call_123"}]}
    , body);
}

test "chat messages serialize custom assistant tool calls" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]ToolCall{
        .{
            .id = "call_123",
            .custom = .{
                .name = "grammar_tool",
                .input = "abc",
            },
        },
    };
    const messages = [_]ChatMessage{
        .{
            .role = "assistant",
            .tool_calls = &tool_calls,
        },
    };
    const request = ChatCompletionsRequest{
        .model = "gpt-4o-mini",
        .messages = &messages,
    };

    const body = try json.stringify(allocator, request, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"model":"gpt-4o-mini","messages":[{"role":"assistant","tool_calls":[{"id":"call_123","type":"custom","custom":{"name":"grammar_tool","input":"abc"}}]}]}
    , body);
}

test "chat completion parses tool calls" {
    const allocator = std.testing.allocator;
    const response = try json.deserializeStructWithArena(ChatCompletion, allocator,
        \\{
        \\  "id": "chatcmpl_123",
        \\  "object": "chat.completion",
        \\  "created": 1710000000,
        \\  "model": "gpt-4o-mini",
        \\  "choices": [{
        \\    "index": 0,
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": null,
        \\      "tool_calls": [{
        \\        "id": "call_123",
        \\        "type": "function",
        \\        "function": {
        \\          "name": "get_weather",
        \\          "arguments": "{\"location\":\"Paris\"}"
        \\        }
        \\      }]
        \\    },
        \\    "finish_reason": "tool_calls"
        \\  }],
        \\  "usage": {
        \\    "prompt_tokens": 10,
        \\    "completion_tokens": 5,
        \\    "total_tokens": 15
        \\  },
        \\  "service_tier": "default"
        \\}
    );
    defer response.deinit();

    try std.testing.expectEqualStrings("tool_calls", response.choices[0].finish_reason);
    try std.testing.expect(response.choices[0].message.content == null);
    const tool_call = response.choices[0].message.tool_calls.?[0];
    try std.testing.expectEqualStrings("call_123", tool_call.id);
    try std.testing.expectEqualStrings("get_weather", tool_call.function.?.name);
    try std.testing.expectEqualStrings("{\"location\":\"Paris\"}", tool_call.function.?.arguments);
}

test "chat completion parses custom tool calls" {
    const allocator = std.testing.allocator;
    const response = try json.deserializeStructWithArena(ChatCompletion, allocator,
        \\{
        \\  "id": "chatcmpl_123",
        \\  "object": "chat.completion",
        \\  "created": 1710000000,
        \\  "model": "gpt-4o-mini",
        \\  "choices": [{
        \\    "index": 0,
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": null,
        \\      "tool_calls": [{
        \\        "id": "call_123",
        \\        "type": "custom",
        \\        "custom": {
        \\          "name": "grammar_tool",
        \\          "input": "abc"
        \\        }
        \\      }]
        \\    },
        \\    "finish_reason": "tool_calls"
        \\  }],
        \\  "usage": {
        \\    "prompt_tokens": 10,
        \\    "completion_tokens": 5,
        \\    "total_tokens": 15
        \\  }
        \\}
    );
    defer response.deinit();

    const tool_call = response.choices[0].message.tool_calls.?[0];
    try std.testing.expectEqualStrings("custom", tool_call.type);
    try std.testing.expectEqualStrings("grammar_tool", tool_call.custom.?.name);
    try std.testing.expectEqualStrings("abc", tool_call.custom.?.input);
    try std.testing.expect(response.service_tier == null);
}

test "chat completion chunk parses partial tool call deltas" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const chunk = try std.json.parseFromSliceLeaky(ChatCompletionChunk, arena.allocator(),
        \\{
        \\  "id": "chatcmpl_123",
        \\  "object": "chat.completion.chunk",
        \\  "created": 1710000000,
        \\  "model": "gpt-4o-mini",
        \\  "service_tier": "default",
        \\  "system_fingerprint": "fp_123",
        \\  "choices": [{
        \\    "index": 0,
        \\    "delta": {
        \\      "tool_calls": [{
        \\        "index": 0,
        \\        "id": "call_123",
        \\        "type": "function",
        \\        "function": {
        \\          "name": "get_weather",
        \\          "arguments": "{\"location\""
        \\        }
        \\      }]
        \\    },
        \\    "finish_reason": null
        \\  }]
        \\}
    ,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    const delta = chunk.choices[0].delta.tool_calls.?[0];
    try std.testing.expectEqual(@as(usize, 0), delta.index);
    try std.testing.expectEqualStrings("call_123", delta.id.?);
    try std.testing.expectEqualStrings("get_weather", delta.function.?.name.?);
    try std.testing.expectEqualStrings("{\"location\"", delta.function.?.arguments.?);
}

test "chat completion chunk accepts missing and null metadata" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const chunk = try std.json.parseFromSliceLeaky(ChatCompletionChunk, arena.allocator(),
        \\{
        \\  "id": "chatcmpl_123",
        \\  "object": "chat.completion.chunk",
        \\  "created": 1710000000,
        \\  "model": "gpt-4o-mini",
        \\  "service_tier": null,
        \\  "choices": [{
        \\    "index": 0,
        \\    "delta": {
        \\      "role": "assistant"
        \\    },
        \\    "finish_reason": null
        \\  }]
        \\}
    ,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    try std.testing.expect(chunk.service_tier == null);
    try std.testing.expect(chunk.system_fingerprint == null);
    try std.testing.expectEqualStrings("assistant", chunk.choices[0].delta.role.?);
}
