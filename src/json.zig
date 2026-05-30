const std = @import("std");

pub const Arena = struct {
    ptr: ?*std.heap.ArenaAllocator = null,

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !Arena {
        try source.skipValue();
        return .{};
    }
};

pub fn stringify(allocator: std.mem.Allocator, value: anytype, options: std.json.Stringify.Options) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, options, &writer.writer);
    return writer.toOwnedSlice();
}

/// Validate the given struct to ensure that it is valid for `parseJson`.
/// This will throw a `@compileError` if the struct isn't valid.
fn validateStruct(comptime T: type) void {
    comptime var valid_arena = false;
    const ti = @typeInfo(T);
    inline for (ti.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "arena")) {
            if (field.type == Arena) {
                valid_arena = true;
            }
        }
    }
    if (!valid_arena) {
        @compileError("Type '" ++ @typeName(T) ++ "' must have a field `arena` of type `json.Arena`");
    }
}

/// Parses a JSON string into `T`, where `T` has an `arena: json.Arena` field.
/// Parsed allocations are owned by that arena and released by the response's `deinit`.
pub fn deserializeStructWithArena(comptime T: type, allocator: std.mem.Allocator, slice: []const u8) !T {
    // validate the struct at compile time
    comptime validateStruct(T);
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    errdefer arena.deinit();

    var self = try std.json.parseFromSliceLeaky(
        T,
        arena.allocator(),
        slice,
        .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        },
    );
    self.arena = .{ .ptr = arena };
    return self;
}

test "deserializeStructWithArena - success" {
    const allocator = std.testing.allocator;
    const slice =
        \\ {
        \\ "hello": "test",
        \\ "world": 32.12
        \\ }
    ;
    const Test = struct {
        hello: []const u8,
        world: f64,
        arena: Arena = .{},
    };
    const result = try deserializeStructWithArena(Test, allocator, slice);
    defer result.arena.ptr.?.child_allocator.destroy(result.arena.ptr.?);
    defer result.arena.ptr.?.deinit();

    try std.testing.expect(std.mem.eql(u8, result.hello, "test"));
}
