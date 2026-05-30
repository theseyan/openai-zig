const std = @import("std");

pub fn text(allocator: std.mem.Allocator, comptime T: type, comptime strict: bool) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try write(&writer.writer, T, strict);
    return writer.toOwnedSlice();
}

pub fn value(allocator: std.mem.Allocator, comptime T: type, comptime strict: bool) !std.json.Value {
    const schema_text = try text(allocator, T, strict);
    defer allocator.free(schema_text);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, schema_text, .{
        .allocate = .alloc_always,
    });
}

pub fn validateObjectRoot(comptime T: type, comptime label: []const u8) void {
    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError(label ++ " requires a named-field struct, not a tuple struct");
            }
        },
        else => @compileError(label ++ " requires a named-field struct root"),
    }
}

fn write(writer: *std.Io.Writer, comptime T: type, comptime strict: bool) !void {
    switch (@typeInfo(T)) {
        .bool => try writeType(writer, "boolean"),
        .int, .comptime_int => try writeType(writer, "integer"),
        .float, .comptime_float => try writeType(writer, "number"),
        .optional => |optional| {
            try writer.writeAll("{\"anyOf\":[");
            try write(writer, optional.child, strict);
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
                    try write(writer, pointer.child, strict);
                    try writer.writeByte('}');
                }
            },
            else => @compileError("JSON schemas only support slices, not pointers"),
        },
        .array => |array| {
            if (array.child == u8) {
                try writeType(writer, "string");
            } else {
                try writer.writeAll("{\"type\":\"array\",\"items\":");
                try write(writer, array.child, strict);
                try writer.writeByte('}');
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("JSON schemas do not support tuple structs");
            }
            try writer.writeAll("{\"type\":\"object\",\"properties\":{");
            inline for (struct_info.fields, 0..) |field, index| {
                if (index != 0) try writer.writeByte(',');
                try writeJsonString(writer, field.name);
                try writer.writeByte(':');
                try write(writer, field.type, strict);
            }
            try writer.writeByte('}');

            const required_count = comptime requiredFieldCount(struct_info.fields, strict);
            if (strict or required_count > 0) {
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
        else => @compileError("unsupported JSON schema type: " ++ @typeName(T)),
    }
}

fn writeType(writer: *std.Io.Writer, value_type: []const u8) !void {
    try writer.writeAll("{\"type\":");
    try writeJsonString(writer, value_type);
    try writer.writeByte('}');
}

fn writeJsonString(writer: *std.Io.Writer, value_string: []const u8) !void {
    try std.json.Stringify.value(value_string, .{}, writer);
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

test "schema text includes strict nullable optional fields as required" {
    const Event = struct {
        name: []const u8,
        location: ?[]const u8 = null,
    };

    const schema = try text(std.testing.allocator, Event, true);
    defer std.testing.allocator.free(schema);

    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"name":{"type":"string"},"location":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["name","location"],"additionalProperties":false}
    , schema);
}
