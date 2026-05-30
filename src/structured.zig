const std = @import("std");
const completions = @import("completions.zig");
const schema = @import("schema.zig");

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
    };
}

pub fn StructuredOutput(comptime T: type) type {
    comptime schema.validateObjectRoot(T, "StructuredOutput");

    return struct {
        arena: std.heap.ArenaAllocator,
        response_format: completions.ResponseFormat,

        const Self = @This();

        pub const Options = struct {
            name: []const u8,
            description: ?[]const u8 = null,
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const arena_allocator = arena.allocator();
            const name = try arena_allocator.dupe(u8, options.name);
            const description = if (options.description) |description|
                try arena_allocator.dupe(u8, description)
            else
                null;
            const schema_value = try schema.value(arena_allocator, T, true);

            return .{
                .arena = arena,
                .response_format = .{
                    .json_schema = .{
                        .name = name,
                        .description = description,
                        .schema = schema_value,
                        .strict = true,
                    },
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// The returned value borrows from this helper; keep it alive until the request is serialized.
        pub fn responseFormat(self: *const Self) completions.ResponseFormat {
            return self.response_format;
        }

        pub fn parse(_: *const Self, allocator: std.mem.Allocator, content: []const u8) !Parsed(T) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const parsed = try std.json.parseFromSliceLeaky(T, arena.allocator(), content, .{
                .allocate = .alloc_always,
            });

            return .{
                .arena = arena,
                .value = parsed,
            };
        }
    };
}

test "structured output builds strict response format and parses content" {
    const Event = struct {
        name: []const u8,
        participants: []const []const u8,
        location: ?[]const u8 = null,
    };

    var output = try StructuredOutput(Event).init(std.testing.allocator, .{
        .name = "calendar_event",
        .description = "Extract a calendar event.",
    });
    defer output.deinit();

    const body = try @import("json.zig").stringify(std.testing.allocator, output.responseFormat(), .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings(
        \\{"type":"json_schema","json_schema":{"name":"calendar_event","description":"Extract a calendar event.","schema":{"type":"object","properties":{"name":{"type":"string"},"participants":{"type":"array","items":{"type":"string"}},"location":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["name","participants","location"],"additionalProperties":false},"strict":true}}
    , body);

    var parsed = try output.parse(std.testing.allocator,
        \\{"name":"Board review","participants":["Ada","Grace"],"location":null}
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Board review", parsed.value.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.participants.len);
    try std.testing.expectEqualStrings("Grace", parsed.value.participants[1]);
    try std.testing.expect(parsed.value.location == null);
}
