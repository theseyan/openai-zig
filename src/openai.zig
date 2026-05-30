//! ***A Zig client for the OpenAI API.***
//!
//! ## Installation
// To install `openai-zig`, run
//!
//!```bash
//! zig fetch --save "git+https://github.com/theseyan/openai-zig"
//!```
//!
//!And add the following to your `build.zig`
//!
//!```zig
//!const openai = b.dependency("openai_zig", .{
//!    .target = target,
//!    .optimize = optimize,
//!});
//!
//!exe.root_module.addImport("openai", openai.module("openai"));
//!```
//!
//!Reference `OpenAI` to create a new client and `OpenAIConfig` to view what configuration options can be used.
const std = @import("std");
pub const client = @import("client.zig");
pub const models = @import("models.zig");
pub const completions = @import("completions.zig");
pub const embeddings = @import("embeddings.zig");
pub const files = @import("files.zig");
/// Contains helper functions for creating your own deserializable types.
pub const json = @import("json.zig");

pub const OpenAI = client.OpenAI;
pub const OpenAIConfig = client.OpenAIConfig;
pub const ChatMessage = completions.ChatMessage;
pub const ChatMessageContent = completions.ChatMessageContent;
pub const ChatContentPart = completions.ChatContentPart;
pub const ChatAllowedTools = completions.ChatAllowedTools;
pub const ChatCustomTool = completions.ChatCustomTool;
pub const ChatTool = completions.ChatTool;
pub const ChatToolChoice = completions.ChatToolChoice;
pub const ChatToolFunction = completions.ChatToolFunction;
pub const ImageUrl = completions.ImageUrl;
pub const ImageDetail = completions.ImageDetail;
pub const ToolCall = completions.ToolCall;
pub const ToolCallCustom = completions.ToolCallCustom;
pub const ToolCallDelta = completions.ToolCallDelta;
pub const ToolCallFunction = completions.ToolCallFunction;
pub const FileCreateRequest = files.FileCreateRequest;
pub const FileExpiresAfter = files.FileExpiresAfter;
pub const FileObject = files.FileObject;
pub const FilePurpose = files.FilePurpose;
pub const FileUpload = files.FileUpload;

test {
    std.testing.refAllDecls(@This());
}
