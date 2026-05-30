<div align="center">
 <h1>openai-zig</h1>
 <img src="https://img.shields.io/badge/zig-0.16.0-%23F7A41D?logo=zig&logoColor=%23F7A41D" />
 <img src="https://img.shields.io/badge/License-MIT-blue" />
 <br />
 <br />
 A Zig client for the OpenAI API.
</div>

## ⭐️ Features ⭐️

- An easy-to-use interface, similar to `openai-python`
- Built-in retry logic
- Environment variable config support for API keys, organization IDs, project IDs, and base URLs
- Chat completions, including streaming responses and image understanding
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
std.log.debug("{s}", .{response.choices[0].message.content});
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
    std.debug.print("{s}", .{val.choices[0].delta.content});
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
Use `openai.ImageUrl.dataUrlAlloc(allocator, "image/png", bytes)` to build one.

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

## Zig 0.16 Notes

openai-zig follows Zig 0.16's explicit IO style. `OpenAI.init` takes both an allocator and a `std.Io` value:

```zig
try OpenAI.init(allocator, io, .{ ... });
```

Environment variables are read from an optional `std.process.Environ.Map` passed as `.environ_map`. When using `std.process.Init`, Zig creates this map for you.

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
