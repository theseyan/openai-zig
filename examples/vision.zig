const std = @import("std");
const openai = @import("openai");

const ChatContentPart = openai.ChatContentPart;
const ChatMessage = openai.ChatMessage;
const OpenAI = openai.OpenAI;

pub fn main(init: std.process.Init) !void {
    var client = try OpenAI.init(init.gpa, init.io, .{
        .environ_map = init.environ_map,
    });
    defer client.deinit();

    const parts = [_]ChatContentPart{
        .{ .text = "What is in this image?" },
        .{ .image_url = .{
            .url = "https://example.com/image.png",
            .detail = .high,
        } },
    };

    var response = try client.chat.completions.create(.{
        .model = "gpt-4o-mini",
        .messages = &[_]ChatMessage{
            .{
                .role = "user",
                .content = .{ .parts = &parts },
            },
        },
    });
    defer response.deinit();

    if (response.choices[0].message.content) |content| {
        std.log.info("{s}", .{content});
    }
}
