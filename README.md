<div align="center">
 <h1>openai-zig</h1>
 <img src="https://img.shields.io/badge/zig-0.16.0-%23F7A41D?logo=zig&logoColor=%23F7A41D" />
 <img src="https://img.shields.io/badge/License-MIT-blue" />
 <br />
 <br />
 A Zig client for the OpenAI API.
</div>

## Features

- An easy-to-use interface, similar to `openai-python`
- Built-in retry logic
- Environment variable config support for API keys, organization IDs, project IDs, and base URLs
- Chat completions, including streaming responses, image/audio/file inputs, and tool calling
- Embeddings
- Models
- Files upload with `multipart/form-data`
- Generic `request`, `requestStream`, and multipart request methods for missing endpoints

## Installation

To install the latest version of `openai-zig`, run

```bash
zig fetch --save "git+https://github.com/theseyan/openai-zig"
```

To install a specific version, run

```bash
zig fetch --save "https://github.com/theseyan/openai-zig/archive/refs/tags/<version>.tar.gz"
```

This branch targets Zig `0.16.0`.

And add the following to your `build.zig`

```zig
const openai = b.dependency("openai_zig", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("openai", openai.module("openai"));
```

## Usage

|✨ Documentation ✨||
|--|--|
|📙 openai-zig Docs |Generated with `zig build docs` |
|📗 OpenAI API Docs|<https://platform.openai.com/docs/api-reference>|

### Client Configuration

```zig
const openai = @import("openai");
const OpenAI = openai.OpenAI;
```

```zig
pub fn main(init: std.process.Init) !void {
    // Uses OPENAI_API_KEY from init.environ_map, or pass .api_key explicitly.
    var client = try OpenAI.init(init.gpa, init.io, .{
        .environ_map = init.environ_map,
    });
    defer client.deinit();
}
```

For applications that manage their own allocator and IO implementation:

```zig
var io: std.Io.Threaded = .init(allocator, .{});
defer io.deinit();

var client = try OpenAI.init(allocator, io.io(), .{
    .api_key = "sk-...",
});
defer client.deinit();
```

### Chat Completions

#### Regular

```zig
const ChatMessage = openai.ChatMessage;

var response = try client.chat.completions.create(.{
    .model = "gpt-4o",
    .messages = &[_]ChatMessage{
        .{
            .role = "user",
            .content = .{ .text = "Hello, world!" },
        },
    },
});
// This will free all the memory allocated for the response
defer response.deinit();
if (response.choices[0].message.content) |content| {
    std.log.debug("{s}", .{content});
}
```

#### Streamed Response

```zig
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
    if (val.choices[0].delta.content) |content| {
        std.debug.print("{s}", .{content});
    }
}
std.debug.print("\n", .{});
```

#### Image Understanding

```zig
const ChatContentPart = openai.ChatContentPart;

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
```

For local image bytes, pass a data URL in `ImageUrl.url`, such as `data:image/png;base64,...`.
Use `openai.ImageUrl.dataUrl(allocator, "image/png", bytes)` to build one.

The same content-part API supports modern multimodal inputs:

```zig
const parts = [_]ChatContentPart{
    .{ .text = "Summarize these inputs." },
    .{ .input_audio = .{ .data = base64_wav, .format = "wav" } },
    .{ .file = .{ .file_id = "file_abc123" } },
};
```

#### Structured Outputs

```zig
const CalendarEvent = struct {
    name: []const u8,
    participants: []const []const u8,
    location: ?[]const u8 = null,
};

var output = try openai.StructuredOutput(CalendarEvent).init(allocator, .{
    .name = "calendar_event",
    .description = "Extract a calendar event.",
});
defer output.deinit();

var response = try client.chat.completions.create(.{
    .model = "gpt-4o-mini",
    .messages = &[_]ChatMessage{
        .{
            .role = "user",
            .content = .{ .text = "Ada and Grace are reviewing the board plan." },
        },
    },
    .response_format = output.responseFormat(),
});
defer response.deinit();

var event = try output.parse(allocator, response.choices[0].message.content.?);
defer event.deinit();
std.log.debug("event: {s}", .{event.value.name});
```

#### Tool Calling

```zig
const ChatTool = openai.ChatTool;
const ToolCall = openai.ToolCall;

const tools = [_]ChatTool{
    .{
        .function = .{
            .name = "get_weather",
            .description = "Get weather for a location",
            .parameters = schema_json_value,
        },
    },
};

var response = try client.chat.completions.create(.{
    .model = "gpt-4o-mini",
    .messages = &[_]ChatMessage{
        .{
            .role = "user",
            .content = .{ .text = "Weather in Paris?" },
        },
    },
    .tools = &tools,
    .tool_choice = .auto,
});
defer response.deinit();

if (response.choices[0].message.tool_calls) |tool_calls| {
    const call = tool_calls[0];
    if (call.function) |function| {
        std.log.debug("Call {s} with {s}", .{ function.name, function.arguments });
    }
}
```

Send tool results back with a tool message:

```zig
const tool_calls = [_]ToolCall{
    .{
        .id = "call_123",
        .function = .{
            .name = "get_weather",
            .arguments = "{\"location\":\"Paris\"}",
        },
    },
};

var follow_up = try client.chat.completions.create(.{
    .model = "gpt-4o-mini",
    .messages = &[_]ChatMessage{
        .{
            .role = "assistant",
            .tool_calls = &tool_calls,
        },
        .{
            .role = "tool",
            .content = .{ .text = "{\"temperature\":\"18C\"}" },
            .tool_call_id = "call_123",
        },
    },
});
defer follow_up.deinit();
```

For idiomatic Zig tool functions, use the compile-time `Tools` helper. It generates function tool schemas from Zig argument structs and dispatches returned tool calls back to the registered functions.

```zig
const WeatherArgs = struct {
    location: []const u8,
    unit: enum { c, f } = .c,
};
const WeatherResult = struct {
    temperature: []const u8,
};

fn getWeather(args: WeatherArgs) !WeatherResult {
    _ = args;
    return .{ .temperature = "18C" };
}

const ToolSet = openai.Tools(.{
    .{
        .name = "get_weather",
        .description = "Get weather for a location",
        .function = getWeather,
    },
});

var tool_set = try ToolSet.init(allocator);
defer tool_set.deinit();

var response = try client.chat.completions.create(.{
    .model = "gpt-4o-mini",
    .messages = &messages,
    .tools = tool_set.definitions,
});
defer response.deinit();

if (response.choices[0].message.tool_calls) |tool_calls| {
    const tool_messages = try tool_set.runAll(allocator, tool_calls);
    defer tool_messages.deinit();
    // Send `tool_messages.messages` in the next chat completion request.
}
```

### Embeddings

```zig
const inputs = [_][]const u8{ "Hello", "Foo", "Bar" };
const response = try client.embeddings.create(.{
    .model = "text-embedding-3-small",
    .input = &inputs,
});
// Don't forget to free resources!
defer response.deinit();
std.log.debug("Model: {s}\nNumber of Embeddings: {d}\nDimensions of Embeddings: {d}", .{
    response.model,
    response.data.len,
    response.data[0].embedding.len,
});
```

### Files

```zig
var response = try client.files.create(.{
    .file = .{
        .filename = "training.jsonl",
        .content = file_bytes,
        .content_type = "application/jsonl",
    },
    .purpose = .@"fine-tune",
});
defer response.deinit();

std.log.debug("Uploaded file: {s}", .{response.id});
```

`files.create` sends `multipart/form-data`. Optional expiration metadata is supported with `.expires_after`.

```zig
var files = try client.files.list(.{
    .purpose = "fine-tune",
    .limit = 20,
    .order = .desc,
});
defer files.deinit();

var file = try client.files.retrieve(files.data[0].id);
defer file.deinit();

const contents = try client.files.content(file.id, 10 * 1024 * 1024);
defer client.allocator.free(contents);

var deleted = try client.files.delete(file.id);
defer deleted.deinit();
```

### Models

#### Get model details

```zig
var response = try client.models.retrieve("gpt-4o");
defer response.deinit();
std.log.debug("Model is owned by '{s}'", .{response.owned_by});
```

#### List all models

```zig
var response = try client.models.list();
defer response.deinit();
std.log.debug("The first model you have available is '{s}'", .{response.data[0].id});
```

## Configuring Logging

By default all logs are enabled for your entire application.
To configure your application, and set the log level for `openai-zig`, include the following in your `main.zig`.

```zig
pub const std_options = std.Options{
    .log_level = .debug, // this sets your app level log config
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{
            .scope = .openai,
            .level = .info, // set to .debug, .warn, .info, or .err
        },
    },
};
```

All logs in `openai-zig` use the scope `.openai`, so if you don't want to see debug/info logs of the requests being sent, set `.level = .err`. This will only display when an error occurs that the client can't recover from.

## Contributions

Contributions are welcome and encouraged! Submit an issue for any bugs/feature requests and open a PR if you tackled one of them!

## Building Docs

```bash
zig build
zig build test
zig build docs
```
