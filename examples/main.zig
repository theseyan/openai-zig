const std = @import("std");
const openai = @import("openai");

const ChatMessage = openai.ChatMessage;
const OpenAI = openai.OpenAI;

pub const std_options = std.Options{
    .log_level = .debug, // this sets your app level log config
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{
            .scope = .openai,
            .level = .info, // set to .debug, .warn, .info, or .err
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // ================== Client Initialization ====================
    // make sure you have an OPENAI_API_KEY environment variable set!
    // or pass it in explicitly...
    // const alternate_config: openai.OpenAIConfig = .{
    //     .api_key = "my-groq-api-key",
    //     .base_url = "https://api.groq.com/openai/v1",
    //     .max_retries = 5,
    // };
    var client = try OpenAI.init(allocator, init.io, .{
        .environ_map = init.environ_map,
    });
    defer client.deinit();

    // ================== Model Retrieval ====================
    var models_response = try client.models.retrieve("gpt-4o");
    defer models_response.deinit();

    std.log.debug("Model is owned by '{s}'", .{models_response.owned_by});

    // ================== Model Listing ====================
    var models_list = try client.models.list();
    defer models_list.deinit();

    std.log.debug("The first model you have available is '{s}'", .{models_list.data[0].id});

    // ================== Chat Completions ====================
    var chat_response = try client.chat.completions.create(.{
        .model = "gpt-4o-mini",
        .messages = &[_]ChatMessage{
            .{
                .role = "user",
                .content = .{ .text = "Hello, world!" },
            },
        },
    });
    // This will free all the memory allocated for the response
    defer chat_response.deinit();
    std.log.debug("{s}", .{chat_response.choices[0].message.content});

    // ================== Chat Completions with Streaming ====================
    var stream = try client.chat.completions.createStream(.{
        .model = "gpt-4o-mini",
        .messages = &[_]ChatMessage{
            .{
                .role = "user",
                .content = .{ .text = "Write me a poem about lizards. Make it a paragraph or two." },
            },
        },
    });
    defer stream.deinit();
    std.debug.print("\n", .{});
    while (try stream.next()) |val| {
        std.debug.print("{s}", .{val.choices[0].delta.content});
    }
    std.debug.print("\n", .{});

    // ================== Embeddings ====================
    const inputs = [_][]const u8{ "Hello", "Foo", "Bar" };
    const embeddings_response = try client.embeddings.create(.{
        .model = "text-embedding-3-small",
        .input = &inputs,
    });
    defer embeddings_response.deinit();
    std.log.debug("Model: {s}\nNumber of Embeddings: {d}\nDimensions of Embeddings: {d}", .{
        embeddings_response.model,
        embeddings_response.data.len,
        embeddings_response.data[0].embedding.len,
    });
}
