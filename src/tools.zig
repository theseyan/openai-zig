const std = @import("std");
const completions = @import("completions.zig");
const json = @import("json.zig");

pub const ToolError = error{
    InvalidToolCall,
    UnknownTool,
    UnsupportedToolCall,
};

pub const ToolMessages = struct {
    allocator: std.mem.Allocator,
    messages: []completions.ChatMessage,

    pub fn deinit(self: *const ToolMessages) void {
        freeMessages(self.allocator, self.messages);
    }
};

pub fn Tools(comptime specs: anytype) type {
    comptime validateSpecs(specs);

    return struct {
        arena: std.heap.ArenaAllocator,
        definitions: []completions.ChatTool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const definitions = try arena.allocator().alloc(completions.ChatTool, specs.len);
            inline for (specs, 0..) |spec, index| {
                const Args = argsType(spec.function);
                const strict = comptime specStrict(spec);
                const schema_text = try schemaText(allocator, Args, strict);
                defer allocator.free(schema_text);
                const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), schema_text, .{});
                definitions[index] = .{
                    .function = .{
                        .name = spec.name,
                        .description = specDescription(spec),
                        .parameters = schema,
                        .strict = if (strict) true else null,
                    },
                };
            }

            return .{
                .arena = arena,
                .definitions = definitions,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn runAll(_: *const Self, allocator: std.mem.Allocator, calls: []const completions.ToolCall) !ToolMessages {
            if (comptime anyRequiresContext(specs)) {
                @compileError("this tool set contains context-aware functions; use runAllWithContext");
            }
            return runAllInternal(allocator, calls, {});
        }

        pub fn runAllWithContext(_: *const Self, allocator: std.mem.Allocator, calls: []const completions.ToolCall, context: anytype) !ToolMessages {
            return runAllInternal(allocator, calls, context);
        }

        fn runAllInternal(allocator: std.mem.Allocator, calls: []const completions.ToolCall, context: anytype) !ToolMessages {
            const messages = try allocator.alloc(completions.ChatMessage, calls.len);
            var completed: usize = 0;
            errdefer {
                freeMessageContents(allocator, messages[0..completed]);
                allocator.free(messages);
            }

            for (calls, 0..) |call, index| {
                messages[index] = try runOne(allocator, call, context);
                completed += 1;
            }

            return .{
                .allocator = allocator,
                .messages = messages,
            };
        }

        fn runOne(allocator: std.mem.Allocator, call: completions.ToolCall, context: anytype) !completions.ChatMessage {
            if (!std.mem.eql(u8, call.type, "function") or call.function == null) {
                return ToolError.UnsupportedToolCall;
            }
            const function = call.function.?;

            inline for (specs) |spec| {
                if (std.mem.eql(u8, function.name, spec.name)) {
                    return runSpec(spec, allocator, call.id, function.arguments, context);
                }
            }

            return ToolError.UnknownTool;
        }
    };
}

fn runSpec(comptime spec: anytype, allocator: std.mem.Allocator, tool_call_id: []const u8, arguments: []const u8, context: anytype) !completions.ChatMessage {
    const Args = argsType(spec.function);
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();

    const args = std.json.parseFromSliceLeaky(Args, args_arena.allocator(), arguments, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return ToolError.InvalidToolCall,
    };

    const result = try callFunction(spec.function, args, context);
    const content = try stringifyResult(allocator, result);
    errdefer allocator.free(content);
    const id = try allocator.dupe(u8, tool_call_id);

    return .{
        .role = "tool",
        .content = .{ .text = content },
        .tool_call_id = id,
    };
}

fn callFunction(comptime function: anytype, args: anytype, context: anytype) !functionReturnPayload(function) {
    const info = functionInfo(function);
    if (comptime info.params.len == 1) {
        return try normalizeReturn(function(args));
    }
    return try normalizeReturn(function(context, args));
}

fn normalizeReturn(value: anytype) !functionReturnPayloadFromType(@TypeOf(value)) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .error_union => try value,
        else => value,
    };
}

fn stringifyResult(allocator: std.mem.Allocator, result: anytype) ![]u8 {
    if (@TypeOf(result) == void) {
        return allocator.dupe(u8, "null");
    }
    return json.stringify(allocator, result, .{
        .emit_null_optional_fields = false,
    });
}

fn freeMessages(allocator: std.mem.Allocator, messages: []completions.ChatMessage) void {
    freeMessageContents(allocator, messages);
    allocator.free(messages);
}

fn freeMessageContents(allocator: std.mem.Allocator, messages: []completions.ChatMessage) void {
    for (messages) |message| {
        if (message.content) |content| switch (content) {
            .text => |text| allocator.free(text),
            .parts => {},
        };
        if (message.tool_call_id) |id| allocator.free(id);
    }
}

fn schemaText(allocator: std.mem.Allocator, comptime T: type, comptime strict: bool) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writeSchema(&writer.writer, T, strict);
    return writer.toOwnedSlice();
}

fn writeSchema(writer: *std.Io.Writer, comptime T: type, comptime strict: bool) !void {
    switch (@typeInfo(T)) {
        .bool => try writeType(writer, "boolean"),
        .int, .comptime_int => try writeType(writer, "integer"),
        .float, .comptime_float => try writeType(writer, "number"),
        .optional => |optional| {
            try writer.writeAll("{\"anyOf\":[");
            try writeSchema(writer, optional.child, strict);
            try writer.writeByte(',');
            try writeType(writer, "null");
            try writer.writeAll("]}");
        },
        .@"enum" => |enum_info| {
            try writer.writeAll("{\"type\":\"string\",\"enum\":[");
            inline for (enum_info.fields, 0..) |field, index| {
                if (index != 0) try writer.writeByte(',');
                try writeJsonString(writer, field.name);
            }
            try writer.writeAll("]}");
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) {
                    try writeType(writer, "string");
                } else {
                    try writer.writeAll("{\"type\":\"array\",\"items\":");
                    try writeSchema(writer, pointer.child, strict);
                    try writer.writeByte('}');
                }
            },
            else => @compileError("tool schemas only support slices, not pointers"),
        },
        .array => |array| {
            if (array.child == u8) {
                try writeType(writer, "string");
            } else {
                try writer.writeAll("{\"type\":\"array\",\"items\":");
                try writeSchema(writer, array.child, strict);
                try writer.writeByte('}');
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("tool schemas do not support tuple structs");
            }
            try writer.writeAll("{\"type\":\"object\",\"properties\":{");
            inline for (struct_info.fields, 0..) |field, index| {
                if (index != 0) try writer.writeByte(',');
                try writeJsonString(writer, field.name);
                try writer.writeByte(':');
                try writeSchema(writer, field.type, strict);
            }
            try writer.writeByte('}');

            const required_count = comptime requiredFieldCount(struct_info.fields, strict);
            if (required_count > 0) {
                try writer.writeAll(",\"required\":[");
                var required_index: usize = 0;
                inline for (struct_info.fields) |field| {
                    if (comptime isRequired(field, strict)) {
                        if (required_index != 0) try writer.writeByte(',');
                        try writeJsonString(writer, field.name);
                        required_index += 1;
                    }
                }
                try writer.writeByte(']');
            }

            try writer.writeAll(",\"additionalProperties\":false}");
        },
        else => @compileError("unsupported tool schema type: " ++ @typeName(T)),
    }
}

fn writeType(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("{\"type\":");
    try writeJsonString(writer, value);
    try writer.writeByte('}');
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn validateSpecs(comptime specs: anytype) void {
    if (specs.len == 0) {
        @compileError("Tools requires at least one tool spec");
    }
    inline for (specs, 0..) |spec, index| {
        if (!@hasField(@TypeOf(spec), "name") or !@hasField(@TypeOf(spec), "function")) {
            @compileError("tool specs must include .name and .function fields");
        }
        validateToolName(spec.name);
        _ = argsType(spec.function);
        inline for (specs, 0..) |previous, previous_index| {
            if (previous_index < index and std.mem.eql(u8, previous.name, spec.name)) {
                @compileError("duplicate tool name: " ++ spec.name);
            }
        }
    }
}

fn validateToolName(comptime name: []const u8) void {
    if (name.len == 0 or name.len > 64) {
        @compileError("tool name must be 1-64 characters");
    }
    for (name) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => @compileError("tool names may only contain letters, numbers, underscores, and dashes"),
        }
    }
}

fn argsType(comptime function: anytype) type {
    const info = functionInfo(function);
    if (info.params.len != 1 and info.params.len != 2) {
        @compileError("tool functions must accept args or context plus args");
    }
    const Args = info.params[info.params.len - 1].type orelse @compileError("tool args must have a concrete type");
    switch (@typeInfo(Args)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("tool args must be a named-field struct, not a tuple struct");
            }
        },
        else => @compileError("tool args must be a struct"),
    }
    return Args;
}

fn functionInfo(comptime function: anytype) std.builtin.Type.Fn {
    const T = @TypeOf(function);
    return switch (@typeInfo(T)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError("tool .function must be a function"),
        },
        else => @compileError("tool .function must be a function"),
    };
}

fn functionReturnPayload(comptime function: anytype) type {
    return functionReturnPayloadFromType(functionInfo(function).return_type orelse @compileError("tool functions must return a value"));
}

fn functionReturnPayloadFromType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |error_union| error_union.payload,
        else => T,
    };
}

fn specDescription(comptime spec: anytype) ?[]const u8 {
    return if (@hasField(@TypeOf(spec), "description")) spec.description else null;
}

fn specStrict(comptime spec: anytype) bool {
    return if (@hasField(@TypeOf(spec), "strict")) spec.strict else false;
}

fn anyRequiresContext(comptime specs: anytype) bool {
    inline for (specs) |spec| {
        if (functionInfo(spec.function).params.len == 2) return true;
    }
    return false;
}

fn isRequired(comptime field: std.builtin.Type.StructField, comptime strict: bool) bool {
    if (strict) return true;
    return field.default_value_ptr == null and @typeInfo(field.type) != .optional;
}

fn requiredFieldCount(comptime fields: []const std.builtin.Type.StructField, comptime strict: bool) usize {
    comptime var count: usize = 0;
    inline for (fields) |field| {
        if (isRequired(field, strict)) count += 1;
    }
    return count;
}

test "typed tools generate function definitions" {
    const Args = struct {
        location: []const u8,
        unit: enum { c, f } = .c,
    };
    const Result = struct { temperature: []const u8 };
    const weather = struct {
        fn getWeather(args: Args) !Result {
            _ = args;
            return .{ .temperature = "18C" };
        }
    }.getWeather;

    const ToolSet = Tools(.{
        .{
            .name = "get_weather",
            .description = "Get weather",
            .function = weather,
        },
    });
    var tools = try ToolSet.init(std.testing.allocator);
    defer tools.deinit();

    const body = try json.stringify(std.testing.allocator, tools.definitions, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings(
        \\[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"location":{"type":"string"},"unit":{"type":"string","enum":["c","f"]}},"required":["location"],"additionalProperties":false}}}]
    , body);
}

test "typed tools run function calls" {
    const Args = struct {
        location: []const u8,
    };
    const Result = struct { temperature: []const u8 };
    const weather = struct {
        fn getWeather(args: Args) !Result {
            try std.testing.expectEqualStrings("Paris", args.location);
            return .{ .temperature = "18C" };
        }
    }.getWeather;

    const ToolSet = Tools(.{
        .{ .name = "get_weather", .function = weather },
    });
    var tools = try ToolSet.init(std.testing.allocator);
    defer tools.deinit();

    const calls = [_]completions.ToolCall{
        .{
            .id = "call_123",
            .function = .{
                .name = "get_weather",
                .arguments = "{\"location\":\"Paris\"}",
            },
        },
    };

    const messages = try tools.runAll(std.testing.allocator, &calls);
    defer messages.deinit();

    try std.testing.expectEqual(@as(usize, 1), messages.messages.len);
    try std.testing.expectEqualStrings("tool", messages.messages[0].role);
    try std.testing.expectEqualStrings("call_123", messages.messages[0].tool_call_id.?);
    try std.testing.expectEqualStrings("{\"temperature\":\"18C\"}", messages.messages[0].content.?.text);
}

test "typed tools support context functions" {
    const Context = struct { prefix: []const u8 };
    const Args = struct { name: []const u8 };
    const Result = struct { message: []const u8 };
    const greet = struct {
        fn greet(ctx: *const Context, args: Args) Result {
            _ = args;
            return .{ .message = ctx.prefix };
        }
    }.greet;

    const ToolSet = Tools(.{
        .{ .name = "greet", .function = greet },
    });
    var tools = try ToolSet.init(std.testing.allocator);
    defer tools.deinit();

    const calls = [_]completions.ToolCall{
        .{
            .id = "call_123",
            .function = .{
                .name = "greet",
                .arguments = "{\"name\":\"Ada\"}",
            },
        },
    };
    const ctx = Context{ .prefix = "hello" };
    const messages = try tools.runAllWithContext(std.testing.allocator, &calls, &ctx);
    defer messages.deinit();

    try std.testing.expectEqualStrings("{\"message\":\"hello\"}", messages.messages[0].content.?.text);
}

test "typed tools clean up earlier messages on later failure" {
    const Args = struct {};
    const Result = struct { ok: bool };
    const ok = struct {
        fn ok(_: Args) Result {
            return .{ .ok = true };
        }
    }.ok;

    const ToolSet = Tools(.{
        .{ .name = "ok", .function = ok },
    });
    var tools = try ToolSet.init(std.testing.allocator);
    defer tools.deinit();

    const calls = [_]completions.ToolCall{
        .{ .id = "call_1", .function = .{ .name = "ok", .arguments = "{}" } },
        .{ .id = "call_2", .function = .{ .name = "missing", .arguments = "{}" } },
    };

    try std.testing.expectError(ToolError.UnknownTool, tools.runAll(std.testing.allocator, &calls));
}

test "typed tools reject invalid args and non-function calls" {
    const Args = struct { value: u8 };
    const Result = struct { ok: bool };
    const ok = struct {
        fn ok(_: Args) Result {
            return .{ .ok = true };
        }
    }.ok;

    const ToolSet = Tools(.{
        .{ .name = "ok", .function = ok },
    });
    var tools = try ToolSet.init(std.testing.allocator);
    defer tools.deinit();

    const invalid_args = [_]completions.ToolCall{
        .{ .id = "call_1", .function = .{ .name = "ok", .arguments = "{\"value\":\"bad\"}" } },
    };
    try std.testing.expectError(ToolError.InvalidToolCall, tools.runAll(std.testing.allocator, &invalid_args));

    const unsupported = [_]completions.ToolCall{
        .{ .id = "call_2", .type = "custom", .custom = .{ .name = "custom", .input = "x" } },
    };
    try std.testing.expectError(ToolError.UnsupportedToolCall, tools.runAll(std.testing.allocator, &unsupported));
}
