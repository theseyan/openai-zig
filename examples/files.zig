const std = @import("std");
const openai = @import("openai");

const OpenAI = openai.OpenAI;

pub fn main(init: std.process.Init) !void {
    var client = try OpenAI.init(init.gpa, init.io, .{
        .environ_map = init.environ_map,
    });
    defer client.deinit();

    const file_bytes =
        \\{"messages":[{"role":"user","content":"Hello"},{"role":"assistant","content":"Hi"}]}
        \\
    ;

    var response = try client.files.create(.{
        .file = .{
            .filename = "training.jsonl",
            .content = file_bytes,
            .content_type = "application/jsonl",
        },
        .purpose = .@"fine-tune",
    });
    defer response.deinit();

    std.log.info("uploaded file: {s}", .{response.id});
}
