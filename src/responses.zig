//! OpenAI Responses API protocol and resource methods.
//!
//! Typed request variants cover the capabilities exposed by this resource. Raw
//! JSON variants are also available as an extension mechanism, while response
//! output items and streaming event payloads are preserved losslessly.
const std = @import("std");
const client = @import("client.zig");
const json = @import("json.zig");
const utils = @import("utils.zig");

pub const ImageDetail = enum { auto, low, high, original };
pub const FileDetail = enum { low, high };
pub const ItemStatus = enum { in_progress, completed, incomplete };
pub const ResponseStatus = enum { completed, failed, in_progress, cancelled, queued, incomplete };
pub const Role = enum { user, assistant, system, developer };
pub const Truncation = enum { auto, disabled };
pub const ServiceTier = enum { auto, default, flex, scale, priority };

pub const MetadataEntry = struct { key: []const u8, value: []const u8 };
pub const Metadata = struct {
    entries: []const MetadataEntry,

    pub fn jsonStringify(self: Metadata, writer: anytype) !void {
        try writer.beginObject();
        for (self.entries) |entry| {
            try writer.objectField(entry.key);
            try writer.write(entry.value);
        }
        try writer.endObject();
    }
};

pub const InputText = struct { text: []const u8 };
pub const InputImage = struct {
    image_url: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
    detail: ?ImageDetail = null,
};
pub const InputFile = struct {
    file_data: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
    file_url: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    detail: ?FileDetail = null,
};

/// A content part in a Responses input message.
pub const InputContent = union(enum) {
    input_text: InputText,
    input_image: InputImage,
    input_file: InputFile,
    raw: std.json.Value,

    pub fn jsonStringify(self: InputContent, writer: anytype) !void {
        if (self == .raw) return writer.write(self.raw);
        try writer.beginObject();
        switch (self) {
            .input_text => |part| {
                try writeType(writer, "input_text");
                try writer.objectField("text");
                try writer.write(part.text);
            },
            .input_image => |part| {
                try writeType(writer, "input_image");
                try writeOptional(writer, "image_url", part.image_url);
                try writeOptional(writer, "file_id", part.file_id);
                try writeOptional(writer, "detail", part.detail);
            },
            .input_file => |part| {
                try writeType(writer, "input_file");
                try writeOptional(writer, "file_data", part.file_data);
                try writeOptional(writer, "file_id", part.file_id);
                try writeOptional(writer, "file_url", part.file_url);
                try writeOptional(writer, "filename", part.filename);
                try writeOptional(writer, "detail", part.detail);
            },
            .raw => unreachable,
        }
        try writer.endObject();
    }
};

pub const MessageContent = union(enum) {
    text: []const u8,
    parts: []const InputContent,

    pub fn jsonStringify(self: MessageContent, writer: anytype) !void {
        switch (self) {
            .text => |text| try writer.write(text),
            .parts => |parts| try writer.write(parts),
        }
    }
};

pub const InputMessage = struct {
    role: Role,
    content: MessageContent,
    phase: ?[]const u8 = null,
};
pub const FunctionCall = struct {
    call_id: []const u8,
    name: []const u8,
    arguments: []const u8,
    id: ?[]const u8 = null,
    status: ?ItemStatus = null,
    namespace: ?[]const u8 = null,
};
pub const FunctionCallOutput = struct {
    call_id: []const u8,
    output: FunctionCallOutputValue,
    id: ?[]const u8 = null,
    status: ?ItemStatus = null,
};
pub const FunctionCallOutputValue = union(enum) {
    text: []const u8,
    content: []const InputContent,
    raw: std.json.Value,

    pub fn jsonStringify(self: FunctionCallOutputValue, writer: anytype) !void {
        switch (self) {
            .text => |text| try writer.write(text),
            .content => |content| try writer.write(content),
            .raw => |value| try writer.write(value),
        }
    }
};
pub const ItemReference = struct { id: []const u8 };

/// An input item. Use `raw` for protocol extensions not represented above.
pub const InputItem = union(enum) {
    message: InputMessage,
    function_call: FunctionCall,
    function_call_output: FunctionCallOutput,
    item_reference: ItemReference,
    raw: std.json.Value,

    pub fn jsonStringify(self: InputItem, writer: anytype) !void {
        if (self == .raw) return writer.write(self.raw);
        try writer.beginObject();
        switch (self) {
            .message => |item| {
                try writeType(writer, "message");
                try writer.objectField("role");
                try writer.write(item.role);
                try writer.objectField("content");
                try writer.write(item.content);
                try writeOptional(writer, "phase", item.phase);
            },
            .function_call => |item| {
                try writeType(writer, "function_call");
                try writer.objectField("call_id");
                try writer.write(item.call_id);
                try writer.objectField("name");
                try writer.write(item.name);
                try writer.objectField("arguments");
                try writer.write(item.arguments);
                try writeOptional(writer, "id", item.id);
                try writeOptional(writer, "status", item.status);
                try writeOptional(writer, "namespace", item.namespace);
            },
            .function_call_output => |item| {
                try writeType(writer, "function_call_output");
                try writer.objectField("call_id");
                try writer.write(item.call_id);
                try writer.objectField("output");
                try writer.write(item.output);
                try writeOptional(writer, "id", item.id);
                try writeOptional(writer, "status", item.status);
            },
            .item_reference => |item| {
                try writeType(writer, "item_reference");
                try writer.objectField("id");
                try writer.write(item.id);
            },
            .raw => unreachable,
        }
        try writer.endObject();
    }
};

pub const ResponseInput = union(enum) {
    text: []const u8,
    items: []const InputItem,

    pub fn jsonStringify(self: ResponseInput, writer: anytype) !void {
        switch (self) {
            .text => |text| try writer.write(text),
            .items => |items| try writer.write(items),
        }
    }
};

pub const FunctionTool = struct {
    name: []const u8,
    parameters: ?std.json.Value = null,
    description: ?[]const u8 = null,
    strict: ?bool = null,
    defer_loading: ?bool = null,
};
pub const CustomTool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    format: ?std.json.Value = null,
    defer_loading: ?bool = null,
};
pub const FileSearchTool = struct {
    vector_store_ids: []const []const u8,
    max_num_results: ?usize = null,
    filters: ?std.json.Value = null,
    ranking_options: ?std.json.Value = null,
};
pub const McpTool = struct {
    server_label: []const u8,
    server_url: ?[]const u8 = null,
    connector_id: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    defer_loading: ?bool = null,
    server_description: ?[]const u8 = null,
    headers: ?std.json.Value = null,
    allowed_tools: ?std.json.Value = null,
    require_approval: ?std.json.Value = null,
};
pub const CodeInterpreterTool = struct { container: std.json.Value };

/// Extra fields for tools whose configuration is intentionally schema-neutral.
/// An empty value serializes only the tool's `type` discriminator.
pub const ToolConfig = struct {
    fields: ?std.json.ObjectMap = null,
};

/// A tool available to the model. Use `raw` for custom protocol extensions.
pub const Tool = union(enum) {
    function: FunctionTool,
    custom: CustomTool,
    web_search: ToolConfig,
    file_search: FileSearchTool,
    computer_use_preview: ToolConfig,
    code_interpreter: CodeInterpreterTool,
    image_generation: ToolConfig,
    mcp: McpTool,
    shell: ToolConfig,
    apply_patch,
    local_shell,
    raw: std.json.Value,

    pub fn jsonStringify(self: Tool, writer: anytype) !void {
        if (self == .raw) return writer.write(self.raw);
        try writer.beginObject();
        switch (self) {
            .function => |tool| try writeTypedFields(writer, "function", tool),
            .custom => |tool| try writeTypedFields(writer, "custom", tool),
            .web_search => |config| try writeTypedConfigFields(writer, "web_search", config),
            .file_search => |tool| try writeTypedFields(writer, "file_search", tool),
            .computer_use_preview => |config| try writeTypedConfigFields(writer, "computer_use_preview", config),
            .code_interpreter => |tool| try writeTypedFields(writer, "code_interpreter", tool),
            .image_generation => |config| try writeTypedConfigFields(writer, "image_generation", config),
            .mcp => |tool| try writeTypedFields(writer, "mcp", tool),
            .shell => |config| try writeTypedConfigFields(writer, "shell", config),
            .apply_patch => try writeType(writer, "apply_patch"),
            .local_shell => try writeType(writer, "local_shell"),
            .raw => unreachable,
        }
        try writer.endObject();
    }
};

pub const AllowedTools = struct {
    mode: []const u8,
    tools: []const std.json.Value,
};
pub const ToolChoice = union(enum) {
    none,
    auto,
    required,
    function: []const u8,
    custom: []const u8,
    mcp: struct { server_label: []const u8, name: ?[]const u8 = null },
    allowed_tools: AllowedTools,
    tool_type: []const u8,
    raw: std.json.Value,

    pub fn jsonStringify(self: ToolChoice, writer: anytype) !void {
        switch (self) {
            .none => try writer.write("none"),
            .auto => try writer.write("auto"),
            .required => try writer.write("required"),
            .function => |name| try writeNamedChoice(writer, "function", name),
            .custom => |name| try writeNamedChoice(writer, "custom", name),
            .mcp => |choice| {
                try writer.beginObject();
                try writeType(writer, "mcp");
                try writer.objectField("server_label");
                try writer.write(choice.server_label);
                try writeOptional(writer, "name", choice.name);
                try writer.endObject();
            },
            .allowed_tools => |choice| {
                try writer.beginObject();
                try writeType(writer, "allowed_tools");
                try writer.objectField("mode");
                try writer.write(choice.mode);
                try writer.objectField("tools");
                try writer.write(choice.tools);
                try writer.endObject();
            },
            .tool_type => |kind| {
                try writer.beginObject();
                try writeType(writer, kind);
                try writer.endObject();
            },
            .raw => |value| try writer.write(value),
        }
    }
};

pub const Reasoning = struct {
    effort: ?[]const u8 = null,
    generate_summary: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    context: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};
pub const JsonSchemaFormat = struct {
    name: []const u8,
    schema: std.json.Value,
    description: ?[]const u8 = null,
    strict: ?bool = null,
};
pub const TextFormat = union(enum) {
    text,
    json_object,
    json_schema: JsonSchemaFormat,
    raw: std.json.Value,

    pub fn jsonStringify(self: TextFormat, writer: anytype) !void {
        switch (self) {
            .text, .json_object => |_, tag| {
                try writer.beginObject();
                try writeType(writer, @tagName(tag));
                try writer.endObject();
            },
            .json_schema => |format| {
                try writer.beginObject();
                try writeTypedFields(writer, "json_schema", format);
                try writer.endObject();
            },
            .raw => |value| try writer.write(value),
        }
    }
};
pub const TextConfig = struct {
    format: ?TextFormat = null,
    verbosity: ?[]const u8 = null,
};
pub const Conversation = union(enum) {
    id: []const u8,
    object: std.json.Value,
    pub fn jsonStringify(self: Conversation, writer: anytype) !void {
        switch (self) {
            .id => |id| try writer.write(id),
            .object => |value| try writer.write(value),
        }
    }
};

pub const StreamOptions = struct { include_obfuscation: ?bool = null };

/// Request body for `responses.create`.
pub const ResponseCreateRequest = struct {
    model: ?[]const u8 = null,
    input: ?ResponseInput = null,
    instructions: ?[]const u8 = null,
    background: ?bool = null,
    context_management: ?[]const std.json.Value = null,
    conversation: ?Conversation = null,
    include: ?[]const []const u8 = null,
    max_output_tokens: ?usize = null,
    metadata: ?Metadata = null,
    parallel_tool_calls: ?bool = null,
    previous_response_id: ?[]const u8 = null,
    prompt: ?std.json.Value = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_retention: ?[]const u8 = null,
    reasoning: ?Reasoning = null,
    safety_identifier: ?[]const u8 = null,
    service_tier: ?ServiceTier = null,
    store: ?bool = null,
    stream: ?bool = null,
    stream_options: ?StreamOptions = null,
    temperature: ?f64 = null,
    text: ?TextConfig = null,
    tool_choice: ?ToolChoice = null,
    tools: ?[]const Tool = null,
    top_logprobs: ?usize = null,
    top_p: ?f64 = null,
    truncation: ?Truncation = null,
    user: ?[]const u8 = null,
};

pub const ResponseError = struct {
    code: []const u8,
    message: []const u8,
};
pub const IncompleteDetails = struct { reason: ?[]const u8 = null };
pub const ResponseUsage = struct {
    input_tokens: usize,
    output_tokens: usize,
    total_tokens: usize,
    input_tokens_details: ?std.json.Value = null,
    output_tokens_details: ?std.json.Value = null,
};

/// An arena-backed Responses API result. Output items remain available as JSON
/// values, and common content can be accessed with the helpers below.
pub const Response = struct {
    id: []const u8,
    object: []const u8,
    created_at: i64,
    model: []const u8,
    output: []const std.json.Value,
    @"error": ?ResponseError = null,
    incomplete_details: ?IncompleteDetails = null,
    instructions: ?std.json.Value = null,
    metadata: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    temperature: ?f64 = null,
    tool_choice: ?std.json.Value = null,
    tools: ?[]const std.json.Value = null,
    top_p: ?f64 = null,
    background: ?bool = null,
    completed_at: ?i64 = null,
    conversation: ?std.json.Value = null,
    max_output_tokens: ?usize = null,
    previous_response_id: ?[]const u8 = null,
    prompt: ?std.json.Value = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_retention: ?[]const u8 = null,
    reasoning: ?std.json.Value = null,
    safety_identifier: ?[]const u8 = null,
    service_tier: ?ServiceTier = null,
    status: ?ResponseStatus = null,
    text: ?std.json.Value = null,
    top_logprobs: ?usize = null,
    truncation: ?Truncation = null,
    usage: ?ResponseUsage = null,
    user: ?[]const u8 = null,
    arena: json.Arena = .{},

    pub fn deinit(self: *const Response) void {
        deinitArena(self.arena);
    }

    /// Appends all `output_text` content in output order. Caller owns the result.
    pub fn outputText(self: *const Response, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        for (self.output) |item| {
            const object = valueObject(item) orelse continue;
            const kind = valueString(object.get("type")) orelse continue;
            if (!std.mem.eql(u8, kind, "message")) continue;
            const content = object.get("content") orelse continue;
            const parts = switch (content) {
                .array => |a| a.items,
                else => continue,
            };
            for (parts) |part| {
                const part_object = valueObject(part) orelse continue;
                const part_type = valueString(part_object.get("type")) orelse continue;
                if (!std.mem.eql(u8, part_type, "output_text")) continue;
                const text = valueString(part_object.get("text")) orelse continue;
                try out.writer.writeAll(text);
            }
        }
        return out.toOwnedSlice();
    }
};

/// An SSE event. Inspect `type` for dispatch; `data` preserves the full payload.
pub const ResponseStreamEvent = struct {
    type: []const u8,
    sequence_number: ?usize = null,
    data: std.json.Value,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ResponseStreamEvent {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        const object = valueObject(value) orelse return error.UnexpectedToken;
        const kind = valueString(object.get("type")) orelse return error.MissingField;
        const sequence = if (object.get("sequence_number")) |v| switch (v) {
            .integer => |n| if (n >= 0) @as(usize, @intCast(n)) else null,
            else => null,
        } else null;
        return .{ .type = kind, .sequence_number = sequence, .data = value };
    }

    pub fn delta(self: ResponseStreamEvent) ?[]const u8 {
        const object = valueObject(self.data) orelse return null;
        return valueString(object.get("delta"));
    }
};

pub const ResponseCompactRequest = struct {
    model: []const u8,
    input: ?ResponseInput = null,
    instructions: ?[]const u8 = null,
    previous_response_id: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_retention: ?[]const u8 = null,
    service_tier: ?ServiceTier = null,
};
pub const CompactedResponse = struct {
    id: []const u8,
    object: []const u8,
    created_at: i64,
    output: []const std.json.Value,
    usage: ResponseUsage,
    arena: json.Arena = .{},
    pub fn deinit(self: *const CompactedResponse) void {
        deinitArena(self.arena);
    }
};

pub const ResponseRetrieveRequest = struct {
    include: ?[]const []const u8 = null,
    include_obfuscation: ?bool = null,
    starting_after: ?usize = null,
};
pub const InputItemListRequest = struct {
    after: ?[]const u8 = null,
    include: ?[]const []const u8 = null,
    limit: ?usize = null,
    order: ?enum { asc, desc } = null,
};
pub const ResponseItemList = struct {
    object: []const u8,
    data: []const std.json.Value,
    first_id: ?[]const u8 = null,
    last_id: ?[]const u8 = null,
    has_more: bool,
    arena: json.Arena = .{},
    pub fn deinit(self: *const ResponseItemList) void {
        deinitArena(self.arena);
    }
};
pub const InputTokenCountRequest = struct {
    conversation: ?Conversation = null,
    input: ?ResponseInput = null,
    instructions: ?[]const u8 = null,
    model: ?[]const u8 = null,
    parallel_tool_calls: ?bool = null,
    previous_response_id: ?[]const u8 = null,
    reasoning: ?Reasoning = null,
    text: ?TextConfig = null,
    tool_choice: ?ToolChoice = null,
    tools: ?[]const Tool = null,
    truncation: ?Truncation = null,
};
pub const InputTokenCountResponse = struct {
    object: []const u8,
    input_tokens: usize,
    arena: json.Arena = .{},
    pub fn deinit(self: *const InputTokenCountResponse) void {
        deinitArena(self.arena);
    }
};

pub const InputItems = struct {
    openai: *const client.OpenAI,
    pub fn init(openai: *const client.OpenAI) InputItems {
        return .{ .openai = openai };
    }
    pub fn deinit(_: *InputItems) void {}

    /// Lists the input items used to generate a stored response.
    /// The caller owns the returned arena-backed value and must call `deinit`.
    pub fn list(self: *const InputItems, response_id: []const u8, request: InputItemListRequest) !ResponseItemList {
        const path = try buildInputItemsPath(self.openai.allocator, response_id, request);
        defer self.openai.allocator.free(path);
        return self.openai.request(.{ .method = .GET, .path = path }, ResponseItemList);
    }
};

pub const InputTokens = struct {
    openai: *const client.OpenAI,
    pub fn init(openai: *const client.OpenAI) InputTokens {
        return .{ .openai = openai };
    }
    pub fn deinit(_: *InputTokens) void {}
    /// Counts the input tokens that the supplied Responses request would use.
    /// The caller owns the returned arena-backed value and must call `deinit`.
    pub fn count(self: *const InputTokens, request: InputTokenCountRequest) !InputTokenCountResponse {
        const body = try stringifyRequest(self.openai.allocator, request);
        defer self.openai.allocator.free(body);
        return self.openai.request(.{ .method = .POST, .path = "/responses/input_tokens", .json = body }, InputTokenCountResponse);
    }
};

/// Container for all `/responses` endpoints.
pub const Responses = struct {
    openai: *const client.OpenAI,
    input_items: InputItems,
    input_tokens: InputTokens,

    pub fn init(openai: *const client.OpenAI) Responses {
        return .{ .openai = openai, .input_items = .init(openai), .input_tokens = .init(openai) };
    }
    pub fn deinit(self: *Responses) void {
        self.input_items.deinit();
        self.input_tokens.deinit();
    }

    /// Creates a non-streaming model response.
    /// The caller owns the returned arena-backed value and must call `deinit`.
    pub fn create(self: *const Responses, request: ResponseCreateRequest) !Response {
        const body = try stringifyRequest(self.openai.allocator, withStream(request, false));
        defer self.openai.allocator.free(body);
        return self.openai.request(.{ .method = .POST, .path = "/responses", .json = body }, Response);
    }
    /// Creates a streaming model response. The caller must call `deinit` on the stream.
    pub fn createStream(self: *const Responses, request: ResponseCreateRequest) !client.Stream(ResponseStreamEvent) {
        return self.createStreamInner(request, null);
    }
    /// Creates a streaming response controlled by a caller-owned abort controller.
    /// The controller must outlive the returned stream and is one-shot after aborting.
    pub fn createStreamAbortable(self: *const Responses, request: ResponseCreateRequest, controller: *client.AbortController) !client.Stream(ResponseStreamEvent) {
        return self.createStreamInner(request, controller);
    }
    fn createStreamInner(self: *const Responses, request: ResponseCreateRequest, controller: ?*client.AbortController) !client.Stream(ResponseStreamEvent) {
        const body = try stringifyRequest(self.openai.allocator, withStream(request, true));
        defer self.openai.allocator.free(body);
        const options: client.OpenAI.OpenAIRequest = .{ .method = .POST, .path = "/responses", .json = body };
        if (controller) |c| return self.openai.requestStreamAbortable(options, ResponseStreamEvent, c);
        return self.openai.requestStream(options, ResponseStreamEvent);
    }
    /// Retrieves a stored response by ID.
    /// The caller owns the returned arena-backed value and must call `deinit`.
    pub fn retrieve(self: *const Responses, response_id: []const u8, request: ResponseRetrieveRequest) !Response {
        const path = try buildResponsePath(self.openai.allocator, response_id, request, false);
        defer self.openai.allocator.free(path);
        return self.openai.request(.{ .method = .GET, .path = path }, Response);
    }
    /// Streams events from a stored or background response.
    /// The caller must call `deinit` on the stream.
    pub fn retrieveStream(self: *const Responses, response_id: []const u8, request: ResponseRetrieveRequest) !client.Stream(ResponseStreamEvent) {
        return self.retrieveStreamInner(response_id, request, null);
    }
    /// Streams a response using a caller-owned abort controller.
    /// The controller must outlive the returned stream and is one-shot after aborting.
    pub fn retrieveStreamAbortable(self: *const Responses, response_id: []const u8, request: ResponseRetrieveRequest, controller: *client.AbortController) !client.Stream(ResponseStreamEvent) {
        return self.retrieveStreamInner(response_id, request, controller);
    }
    fn retrieveStreamInner(self: *const Responses, response_id: []const u8, request: ResponseRetrieveRequest, controller: ?*client.AbortController) !client.Stream(ResponseStreamEvent) {
        const path = try buildResponsePath(self.openai.allocator, response_id, request, true);
        defer self.openai.allocator.free(path);
        const options: client.OpenAI.OpenAIRequest = .{ .method = .GET, .path = path };
        if (controller) |c| return self.openai.requestStreamAbortable(options, ResponseStreamEvent, c);
        return self.openai.requestStream(options, ResponseStreamEvent);
    }
    /// Deletes a stored response by ID.
    pub fn delete(self: *const Responses, response_id: []const u8) !void {
        const path = try buildActionPath(self.openai.allocator, response_id, null);
        defer self.openai.allocator.free(path);
        return self.openai.request(.{ .method = .DELETE, .path = path }, null);
    }
    /// Cancels a background response.
    /// The caller owns the returned arena-backed value and must call `deinit`.
    pub fn cancel(self: *const Responses, response_id: []const u8) !Response {
        const path = try buildActionPath(self.openai.allocator, response_id, "cancel");
        defer self.openai.allocator.free(path);
        return self.openai.request(.{ .method = .POST, .path = path }, Response);
    }
    /// Compacts a conversation into a smaller set of reusable output items.
    /// The caller owns the returned arena-backed value and must call `deinit`.
    pub fn compact(self: *const Responses, request: ResponseCompactRequest) !CompactedResponse {
        const body = try stringifyRequest(self.openai.allocator, request);
        defer self.openai.allocator.free(body);
        return self.openai.request(.{ .method = .POST, .path = "/responses/compact", .json = body }, CompactedResponse);
    }
};

fn stringifyRequest(allocator: std.mem.Allocator, request: anytype) ![]u8 {
    return json.stringify(allocator, request, .{ .emit_null_optional_fields = false });
}
fn withStream(request: ResponseCreateRequest, enabled: bool) ResponseCreateRequest {
    var result = request;
    result.stream = enabled;
    return result;
}
fn deinitArena(arena: json.Arena) void {
    arena.ptr.?.deinit();
    arena.ptr.?.child_allocator.destroy(arena.ptr.?);
}
fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}
fn valueString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
fn writeType(writer: anytype, kind: []const u8) !void {
    try writer.objectField("type");
    try writer.write(kind);
}
fn writeOptional(writer: anytype, name: []const u8, value: anytype) !void {
    if (value) |present| {
        try writer.objectField(name);
        try writer.write(present);
    }
}
fn writeTypedFields(writer: anytype, kind: []const u8, value: anytype) !void {
    try writeType(writer, kind);
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
        const field_value = @field(value, field.name);
        if (@typeInfo(field.type) == .optional) {
            try writeOptional(writer, field.name, field_value);
        } else {
            try writer.objectField(field.name);
            try writer.write(field_value);
        }
    }
}
fn writeTypedConfigFields(writer: anytype, kind: []const u8, config: ToolConfig) !void {
    try writeType(writer, kind);
    if (config.fields) |fields| {
        var it = fields.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "type")) continue;
            try writer.objectField(entry.key_ptr.*);
            try writer.write(entry.value_ptr.*);
        }
    }
}
fn writeNamedChoice(writer: anytype, kind: []const u8, name: []const u8) !void {
    try writer.beginObject();
    try writeType(writer, kind);
    try writer.objectField("name");
    try writer.write(name);
    try writer.endObject();
}

fn buildActionPath(allocator: std.mem.Allocator, response_id: []const u8, action: ?[]const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("/responses/");
    try utils.writePercentEncoded(&writer.writer, response_id);
    if (action) |suffix| {
        try writer.writer.writeByte('/');
        try writer.writer.writeAll(suffix);
    }
    return writer.toOwnedSlice();
}
fn appendQuery(writer: *std.Io.Writer, started: *bool, name: []const u8, value: []const u8) !void {
    try writer.writeByte(if (started.*) '&' else '?');
    started.* = true;
    try utils.writePercentEncoded(writer, name);
    try writer.writeByte('=');
    try utils.writePercentEncoded(writer, value);
}
fn appendQueryArray(writer: *std.Io.Writer, started: *bool, name: []const u8, values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        var name_buffer: [128]u8 = undefined;
        const indexed_name = try std.fmt.bufPrint(&name_buffer, "{s}[{d}]", .{ name, index });
        try appendQuery(writer, started, indexed_name, value);
    }
}
fn buildResponsePath(allocator: std.mem.Allocator, response_id: []const u8, request: ResponseRetrieveRequest, streaming: bool) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("/responses/");
    try utils.writePercentEncoded(&writer.writer, response_id);
    var started = false;
    if (request.include) |includes| try appendQueryArray(&writer.writer, &started, "include", includes);
    if (request.include_obfuscation) |value| try appendQuery(&writer.writer, &started, "include_obfuscation", if (value) "true" else "false");
    if (request.starting_after) |value| {
        var buf: [32]u8 = undefined;
        try appendQuery(&writer.writer, &started, "starting_after", try std.fmt.bufPrint(&buf, "{d}", .{value}));
    }
    if (streaming) try appendQuery(&writer.writer, &started, "stream", "true");
    return writer.toOwnedSlice();
}
fn buildInputItemsPath(allocator: std.mem.Allocator, response_id: []const u8, request: InputItemListRequest) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("/responses/");
    try utils.writePercentEncoded(&writer.writer, response_id);
    try writer.writer.writeAll("/input_items");
    var started = false;
    if (request.after) |value| try appendQuery(&writer.writer, &started, "after", value);
    if (request.include) |includes| try appendQueryArray(&writer.writer, &started, "include", includes);
    if (request.limit) |value| {
        var buf: [32]u8 = undefined;
        try appendQuery(&writer.writer, &started, "limit", try std.fmt.bufPrint(&buf, "{d}", .{value}));
    }
    if (request.order) |value| try appendQuery(&writer.writer, &started, "order", @tagName(value));
    return writer.toOwnedSlice();
}

test "create request serializes multimodal input tools and reasoning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"object\"}", .{});
    const content = [_]InputContent{
        .{ .input_text = .{ .text = "What is shown?" } },
        .{ .input_image = .{ .image_url = "https://example.com/cat.png", .detail = .high } },
    };
    const items = [_]InputItem{.{ .message = .{ .role = .user, .content = .{ .parts = &content } } }};
    const tools = [_]Tool{.{ .function = .{ .name = "weather", .parameters = schema_value, .strict = true } }};
    const body = try stringifyRequest(std.testing.allocator, ResponseCreateRequest{
        .model = "gpt-5",
        .input = .{ .items = &items },
        .reasoning = .{ .effort = "high", .summary = "auto" },
        .tools = &tools,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-5\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"What is shown?\"},{\"type\":\"input_image\",\"image_url\":\"https://example.com/cat.png\",\"detail\":\"high\"}]}],\"reasoning\":{\"effort\":\"high\",\"summary\":\"auto\"},\"tools\":[{\"type\":\"function\",\"name\":\"weather\",\"parameters\":{\"type\":\"object\"},\"strict\":true}]}",
        body,
    );
}

test "response parses losslessly and extracts output text" {
    const response = try json.deserializeStructWithArena(Response, std.testing.allocator,
        \\{"id":"resp_1","object":"response","created_at":1,"model":"gpt-5","output":[{"id":"msg_1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello ","annotations":[]},{"type":"output_text","text":"world","annotations":[]}]},{"type":"future_tool_call","future_field":{"nested":true}}],"status":"completed"}
    );
    defer response.deinit();
    const text_output = try response.outputText(std.testing.allocator);
    defer std.testing.allocator.free(text_output);
    try std.testing.expectEqualStrings("Hello world", text_output);
    try std.testing.expect(response.output[1].object.get("future_field") != null);
}

test "stream event preserves arbitrary fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const event = try std.json.parseFromSliceLeaky(ResponseStreamEvent, arena.allocator(),
        \\{"type":"response.output_text.delta","sequence_number":7,"delta":"hi","obfuscation":"abc"}
    , .{});
    try std.testing.expectEqualStrings("response.output_text.delta", event.type);
    try std.testing.expectEqual(@as(?usize, 7), event.sequence_number);
    try std.testing.expectEqualStrings("hi", event.delta().?);
    try std.testing.expect(event.data.object.get("obfuscation") != null);
}

test "response paths percent encode ids and query parameters" {
    const path = try buildResponsePath(std.testing.allocator, "resp/a?#", .{
        .include = &.{"reasoning.encrypted_content"},
        .starting_after = 42,
    }, true);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/responses/resp%2Fa%3F%23?include%5B0%5D=reasoning.encrypted_content&starting_after=42&stream=true", path);
}

test "function call outputs serialize continuation items" {
    const items = [_]InputItem{.{ .function_call_output = .{
        .call_id = "call_123",
        .output = .{ .text = "72 F" },
    } }};
    const body = try stringifyRequest(std.testing.allocator, ResponseCreateRequest{
        .model = "gpt-5",
        .previous_response_id = "resp_123",
        .input = .{ .items = &items },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-5\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_123\",\"output\":\"72 F\"}],\"previous_response_id\":\"resp_123\"}",
        body,
    );
}

test "structured output and tool choice serialize protocol shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"object\",\"additionalProperties\":false}", .{});
    const body = try stringifyRequest(std.testing.allocator, ResponseCreateRequest{
        .text = .{ .format = .{ .json_schema = .{
            .name = "answer",
            .schema = schema_value,
            .strict = true,
        } } },
        .tool_choice = .{ .function = "lookup" },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"answer\",\"schema\":{\"type\":\"object\",\"additionalProperties\":false},\"strict\":true}},\"tool_choice\":{\"type\":\"function\",\"name\":\"lookup\"}}",
        body,
    );
}

test "methods override caller stream mode" {
    const request = ResponseCreateRequest{ .model = "gpt-5", .stream = true };
    try std.testing.expectEqual(false, withStream(request, false).stream.?);
    try std.testing.expectEqual(true, withStream(request, true).stream.?);
}

test "input item and action paths cover endpoint surface" {
    const input_path = try buildInputItemsPath(std.testing.allocator, "resp/a", .{
        .after = "item/a",
        .include = &.{ "file_search_call.results", "message.input_image.image_url" },
        .limit = 25,
        .order = .asc,
    });
    defer std.testing.allocator.free(input_path);
    try std.testing.expectEqualStrings(
        "/responses/resp%2Fa/input_items?after=item%2Fa&include%5B0%5D=file_search_call.results&include%5B1%5D=message.input_image.image_url&limit=25&order=asc",
        input_path,
    );

    const cancel_path = try buildActionPath(std.testing.allocator, "resp/a", "cancel");
    defer std.testing.allocator.free(cancel_path);
    try std.testing.expectEqualStrings("/responses/resp%2Fa/cancel", cancel_path);

    const delete_path = try buildActionPath(std.testing.allocator, "resp/a", null);
    defer std.testing.allocator.free(delete_path);
    try std.testing.expectEqualStrings("/responses/resp%2Fa", delete_path);
}

test "input token count request covers supported controls" {
    const tools = [_]Tool{.{ .mcp = .{
        .server_label = "docs",
        .server_url = "https://example.com/mcp",
        .authorization = "Bearer token",
        .defer_loading = true,
    } }};
    const body = try stringifyRequest(std.testing.allocator, InputTokenCountRequest{
        .model = "gpt-5",
        .input = .{ .text = "hello" },
        .reasoning = .{ .effort = "low", .generate_summary = "auto" },
        .tool_choice = .auto,
        .tools = &tools,
        .truncation = .auto,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"input\":\"hello\",\"model\":\"gpt-5\",\"reasoning\":{\"effort\":\"low\",\"generate_summary\":\"auto\"},\"tool_choice\":\"auto\",\"tools\":[{\"type\":\"mcp\",\"server_label\":\"docs\",\"server_url\":\"https://example.com/mcp\",\"authorization\":\"Bearer token\",\"defer_loading\":true}],\"truncation\":\"auto\"}",
        body,
    );
}

test "schema-neutral tool configuration merges object fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"type":"ignored","quality":"high"}
    , .{});
    const tools = [_]Tool{
        .{ .web_search = .{} },
        .{ .image_generation = .{ .fields = config_value.object } },
    };
    const body = try stringifyRequest(std.testing.allocator, ResponseCreateRequest{ .tools = &tools });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"tools\":[{\"type\":\"web_search\"},{\"type\":\"image_generation\",\"quality\":\"high\"}]}",
        body,
    );
}
