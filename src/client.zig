//!## Example
//!```zig
//!const openai = @import("openai");
//!const OpenAI = openai.OpenAI;
//!pub fn main() !void {
//!     var io: std.Io.Threaded = .init(allocator, .{});
//!     defer io.deinit();
//!     const client = try OpenAI.init(allocator, io.io(), .{});
//!     defer client.deinit();
//!     // ... call client.chat.completions.create
//!}
//!```
//!
const std = @import("std");
const chat = @import("chat.zig");
const completions = @import("completions.zig");
const embeddings = @import("embeddings.zig");
const files = @import("files.zig");
const models = @import("models.zig");
const json = @import("json.zig");

const log = std.log.scoped(.openai);

const INITIAL_RETRY_DELAY = 0.5;
const MAX_RETRY_DELAY = 8;
pub const DEFAULT_USER_AGENT = "openai-zig/0.1.0";

const ApiError = struct {
    message: []const u8,
    type: []const u8,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

/// OpenAI Error Response Body.
/// Currently not exposed.
const ApiErrorResponse = struct {
    @"error": ApiError,
    arena: json.Arena = .{},

    pub fn deinit(self: *const ApiErrorResponse) void {
        self.arena.ptr.?.deinit();
        self.arena.ptr.?.child_allocator.destroy(self.arena.ptr.?);
    }
};

pub fn Stream(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        reader: *std.Io.Reader,
        request: *std.http.Client.Request,
        client: *std.http.Client,
        transfer_buffer: []u8,

        pub fn init(allocator: std.mem.Allocator, http_client: *std.http.Client, request: *std.http.Client.Request, response: *std.http.Client.Response) !@This() {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer allocator.destroy(arena);

            const transfer_buffer = try allocator.alloc(u8, 64 * 1024);
            errdefer allocator.free(transfer_buffer);

            return .{
                .arena = arena,
                .request = request,
                .client = http_client,
                .reader = response.reader(transfer_buffer),
                .transfer_buffer = transfer_buffer,
            };
        }

        pub fn deinit(self: *@This()) void {
            const allocator = self.arena.child_allocator;
            allocator.free(self.transfer_buffer);
            self.arena.deinit();
            self.request.deinit();
            self.client.deinit();
            allocator.destroy(self.request);
            allocator.destroy(self.client);
            allocator.destroy(self.arena);
        }

        pub fn next(self: *@This()) !?T {
            while (try self.reader.takeDelimiter('\n')) |line| {
                if (std.mem.trim(u8, line, " \t\r\n").len != 0) {
                    var it = std.mem.splitSequence(u8, line, "data:");
                    _ = it.next();
                    const stripped = std.mem.trim(u8, it.rest(), " \t\r\n");
                    if (stripped.len == 0) continue;
                    if (std.mem.eql(u8, "[DONE]", stripped)) return null;
                    return try std.json.parseFromSliceLeaky(T, self.arena.allocator(), stripped, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    });
                }
            }
            return null;
        }
    };
}

/// Different OpenAI API errors:
/// https://platform.openai.com/docs/guides/error-codes
pub const OpenAIError = error{
    /// 400 - Bad Request
    /// Generic bad request error
    BadRequest,

    /// 404 - Not Found
    /// Model/resource isn't found
    NotFound,

    /// 401 - Invalid Authentication
    /// Cause: Invalid API key, incorrect API key, or missing organization membership
    /// Solution: Verify API key is correct, clear cache, or ensure organization membership
    InvalidAuthentication,

    /// 403 - Not Supported
    /// Cause: Accessing API from an unsupported country/region/territory
    /// Solution: See documentation for supported regions
    NotSupported,

    /// 429 - Rate Limit
    /// Cause: Too many requests or exceeded quota
    /// Solution: Pace requests according to rate limits or upgrade plan/billing
    RateLimit,

    /// 500 - Server Error
    /// Cause: Internal server error
    /// Solution: Retry after waiting, contact support if persistent
    ServerError,

    /// 503 - Service Overloaded
    /// Cause: Server is currently overloaded
    /// Solution: Retry request after waiting
    ServiceOverloaded,

    /// Unknown error occurred
    Unknown,
};

fn getErrorFromStatus(status: std.http.Status) OpenAIError {
    return switch (status) {
        .bad_request => OpenAIError.BadRequest,
        .not_found => OpenAIError.NotFound,
        .unauthorized => OpenAIError.InvalidAuthentication,
        .forbidden => OpenAIError.NotSupported,
        .too_many_requests => OpenAIError.RateLimit,
        .internal_server_error => OpenAIError.ServerError,
        .service_unavailable => OpenAIError.ServiceOverloaded,
        else => OpenAIError.Unknown,
    };
}

fn handleErrorResponse(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) OpenAIError {
    const err = json.deserializeStructWithArena(ApiErrorResponse, allocator, body) catch {
        log.err("HTTP {d} {s}: {s}", .{ @intFromEnum(status), status.phrase() orelse "Unknown", body });
        return getErrorFromStatus(status);
    };
    defer err.deinit();
    log.err("{s} ({s}): {s}", .{ err.@"error".type, err.@"error".code orelse "None", err.@"error".message });
    return getErrorFromStatus(status);
}

fn classifyErrorResponse(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) OpenAIError {
    const err = json.deserializeStructWithArena(ApiErrorResponse, allocator, body) catch {
        return getErrorFromStatus(status);
    };
    defer err.deinit();
    return getErrorFromStatus(status);
}

/// Options to be passed through to the `OpenAI.init` function.
pub const OpenAIConfig = struct {
    /// Your OpenAI API key. If left null, it will attempt to read from the `OPENAI_API_KEY` environment variable.
    api_key: ?[]const u8 = null,
    /// Your OpenAI base url. If left null, it will attempt to read from the `OPENAI_BASE_URL` environment variable, otherwise will default to `"https://api.openai.com/v1"`.
    base_url: ?[]const u8 = null,
    /// Your OpenAI organization id. If left null, it will attempt to read from `OPENAI_ORG_ID` environment variable.
    organization: ?[]const u8 = null,
    /// Your OpenAI project id. If left null, it will attempt to read from `OPENAI_PROJECT_ID` in `environ_map`.
    project: ?[]const u8 = null,
    /// The maximum number of retries the client will attempt. Defaults to `3`.
    max_retries: usize = 3,
    /// User-Agent header sent with every request. Defaults to `openai-zig/0.1.0`.
    user_agent: ?[]const u8 = null,
    /// Optional environment map used to load OpenAI API config when explicit fields are null.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// A general purpose openai client that initializes all base parameters (API key, Base URL, Org ID, Project ID)
/// and through which all requests should be made through. The creator must call `deinit` to clean up all resources created
/// by this struct.
pub const OpenAI = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    chat: chat.Chat,
    models: models.Models,
    embeddings: embeddings.Embeddings,
    files: files.Files,
    api_key: []const u8,
    base_url: []const u8,
    organization: ?[]const u8,
    project: ?[]const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    arena: *std.heap.ArenaAllocator,
    max_retries: usize,

    /// Errors pertaining to OpenAI struct creation
    pub const OpenAIClientError = error{
        OpenAIAPIKeyNotSet,
        MemoryError,
    };

    fn moveNullableString(self: *OpenAI, str: ?[]const u8) !?[]const u8 {
        if (str) |s| {
            return self.arena.allocator().dupe(u8, s) catch {
                return OpenAIClientError.MemoryError;
            };
        } else {
            return null;
        }
    }

    fn configValue(explicit: ?[]const u8, env_map: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
        return explicit orelse if (env_map) |map| map.get(name) else null;
    }

    /// Creates a new `OpenAI` object, initializing subcomponents and reading in environment variables for
    /// `base_url`, `api_key`, `organization`, and `project`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: OpenAIConfig) OpenAIClientError!*OpenAI {
        const arena = allocator.create(std.heap.ArenaAllocator) catch {
            return OpenAIClientError.MemoryError;
        };
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer blk: {
            arena.deinit();
            allocator.destroy(arena);
            break :blk;
        }
        var self = allocator.create(OpenAI) catch {
            return OpenAIClientError.MemoryError;
        };
        self.* = OpenAI{
            .allocator = allocator,
            .io = io,
            .chat = undefined, // have to pass in self
            .embeddings = undefined, // have to pass in self
            .files = undefined, // have to pass in self
            .models = undefined, // have to pass in self
            .api_key = undefined,
            .base_url = undefined,
            .organization = null,
            .project = null,
            .headers = undefined, // set below
            .extra_headers = &.{},
            .arena = arena,
            .max_retries = config.max_retries,
        };
        errdefer allocator.destroy(self);

        const env_map = config.environ_map;
        const api_key_value = configValue(config.api_key, env_map, "OPENAI_API_KEY");
        const base_url_value = configValue(config.base_url, env_map, "OPENAI_BASE_URL") orelse "https://api.openai.com/v1";
        const organization_value = configValue(config.organization, env_map, "OPENAI_ORG_ID");
        const project_value = configValue(config.project, env_map, "OPENAI_PROJECT_ID");
        const user_agent_value = config.user_agent orelse DEFAULT_USER_AGENT;

        const api_key = try self.moveNullableString(api_key_value);
        const base_url = try self.moveNullableString(base_url_value);
        const organization = try self.moveNullableString(organization_value);
        const project = try self.moveNullableString(project_value);
        const user_agent = try self.moveNullableString(user_agent_value);

        // init client config
        self.api_key = api_key orelse {
            return OpenAIClientError.OpenAIAPIKeyNotSet;
        };
        self.base_url = base_url orelse {
            unreachable; // default is provided, this can't happen
        };
        self.organization = organization;
        self.project = project;

        // init sub components
        self.chat = chat.Chat.init(self);
        self.embeddings = embeddings.Embeddings.init(self);
        self.files = files.Files.init(self);
        self.models = models.Models.init(self);

        // client headers
        const auth_header = std.fmt.allocPrint(self.arena.allocator(), "Bearer {s}", .{self.api_key}) catch {
            return OpenAIClientError.MemoryError;
        };
        self.headers = .{
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = user_agent.? },
            .content_type = .{ .override = "application/json" },
        };
        if (self.project != null or self.organization != null) {
            var arr = std.ArrayList(std.http.Header).initCapacity(self.arena.allocator(), 2) catch {
                return OpenAIClientError.MemoryError;
            };
            defer arr.deinit(self.arena.allocator());
            if (self.project) |p| {
                arr.append(self.arena.allocator(), .{
                    .name = "OpenAI-Project",
                    .value = p,
                }) catch return OpenAIClientError.MemoryError;
            }
            if (self.organization) |o| {
                arr.append(self.arena.allocator(), .{
                    .name = "OpenAI-Organization",
                    .value = o,
                }) catch return OpenAIClientError.MemoryError;
            }
            self.extra_headers = arr.toOwnedSlice(self.arena.allocator()) catch return OpenAIClientError.MemoryError;
        }
        return self;
    }

    pub fn deinit(self: *OpenAI) void {
        self.chat.deinit();
        self.embeddings.deinit();
        self.files.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.allocator.destroy(self);
    }

    pub const OpenAIRequest = struct {
        method: std.http.Method,
        path: []const u8,
        json: ?[]const u8 = null,
    };

    pub const MultipartRequest = struct {
        path: []const u8,
        body: []const u8,
        content_type: []const u8,
    };

    /// Creates a request to OpenAI expecting SSE events. Returns a `Stream` struct wrapping the response type.
    /// Makes a request to the OpenAI base_url provided to the client, with the corresponding method, path, and options provided.
    /// If there isn't a typed method for an endpoint, this can be used and will automatically pass in required headers.
    /// ```zig
    /// var response: Stream(ResponseBodyStruct) = try self.openai.requestStream(.{
    ///     .method = .POST, // .GET, .PUT, .etc.
    //      .path = "/my/endpoint",
    ///     .json = body,
    /// }, ResponseBodyStruct);
    /// defer response.deinit();
    /// while (try response.next()) |val| {
    ///     std.debug.print("{s}", .{val.choices[0].delta.content});
    /// }
    /// ```
    /// The user is responsible for managing that memory.
    /// Call `deinit` on the response.
    pub fn requestStream(self: *const OpenAI, options: OpenAIRequest, comptime ResponseType: type) !Stream(ResponseType) {
        const method = options.method;
        const path = options.path;
        const allocator = self.allocator;
        const url_string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, path });
        defer allocator.free(url_string);

        const uri = try std.Uri.parse(url_string);

        var http_client = try allocator.create(std.http.Client);
        http_client.* = std.http.Client{ .allocator = allocator, .io = self.io };
        errdefer allocator.destroy(http_client);
        errdefer http_client.deinit();
        var backoff: f32 = INITIAL_RETRY_DELAY;

        var req = try allocator.create(std.http.Client.Request);
        errdefer allocator.destroy(req);
        errdefer req.deinit();

        for (0..self.max_retries + 1) |attempt| {
            req.* = try std.http.Client.request(http_client, method, uri, .{
                .headers = self.headers,
                .extra_headers = self.extra_headers,
                .redirect_behavior = .unhandled,
            });

            if (options.json) |body| {
                req.transfer_encoding = .{ .content_length = body.len };
                var body_writer = try req.sendBodyUnflushed(&.{});
                log.debug("{s}", .{body});
                try body_writer.writer.writeAll(body);
                try body_writer.end();
                try req.connection.?.flush();
            } else {
                try req.sendBodiless();
            }
            var response = try req.receiveHead(&.{});
            const status_int = @intFromEnum(response.head.status);
            log.info("{s} - {s} - {d} {s}", .{ @tagName(method), url_string, status_int, response.head.status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt != self.max_retries and status_int >= 429) {
                    // retry on 429, 500, and 503
                    log.info("Retrying ({d}/{d}) after {d} seconds.", .{ attempt + 1, self.max_retries, backoff });
                    try std.Io.sleep(self.io, .fromNanoseconds(@intFromFloat(backoff * std.time.ns_per_s)), .awake);
                    backoff = if (backoff * 2 <= MAX_RETRY_DELAY) backoff * 2 else MAX_RETRY_DELAY;
                    req.deinit();
                } else {
                    var transfer_buffer: [64 * 1024]u8 = undefined;
                    const reader = response.reader(&transfer_buffer);
                    const body = try reader.allocRemaining(allocator, .limited(1024 * 1024));
                    defer allocator.free(body);
                    return handleErrorResponse(allocator, response.head.status, body);
                }
            } else {
                return try Stream(ResponseType).init(allocator, http_client, req, &response);
            }
        }
        // max_retries must be >= 0 (since it's usize) and loop condition is 0..max_retries+1
        unreachable;
    }

    /// Makes a request to the OpenAI base_url provided to the client, with the corresponding method, path, and options provided.
    /// If there isn't a typed method for an endpoint, this can be used and will automatically pass in required headers.
    /// ```zig
    /// const response: ResponseBodyStruct = try self.openai.request(.{
    ///     .method = .POST, // .GET, .PUT, .etc.
    //      .path = "/my/endpoint",
    ///     .json = body,
    /// }, ResponseBodyStruct); // pass in null for no response body
    /// ```
    /// Note that the `ResponseType` _must_ have a field called `arena` of type `*std.heap.ArenaAllocator` (or you will get a @compileError).
    /// This will be used to store the allocator that allocates all memory for the resulting struct.
    /// The user is responsible for managing that memory.
    pub fn request(self: *const OpenAI, options: OpenAIRequest, comptime ResponseType: ?type) !if (ResponseType) |T| T else void {
        const method = options.method;
        const path = options.path;
        const allocator = self.allocator;
        const url_string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, path });
        defer allocator.free(url_string);

        const uri = try std.Uri.parse(url_string);

        var client = std.http.Client{ .allocator = allocator, .io = self.io };
        defer client.deinit();
        var backoff: f32 = INITIAL_RETRY_DELAY;

        for (0..self.max_retries + 1) |attempt| {
            var response_writer = std.Io.Writer.Allocating.init(allocator);
            defer response_writer.deinit();
            const result = try client.fetch(.{
                .location = .{ .uri = uri },
                .method = method,
                .payload = options.json,
                .headers = self.headers,
                .extra_headers = self.extra_headers,
                .redirect_behavior = .unhandled,
                .response_writer = &response_writer.writer,
            });
            if (options.json) |body| log.debug("{s}", .{body});
            const body = try response_writer.toOwnedSlice();
            defer allocator.free(body);

            const status_int = @intFromEnum(result.status);
            log.info("{s} - {s} - {d} {s}", .{ @tagName(method), url_string, status_int, result.status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt != self.max_retries and status_int >= 429) {
                    // retry on 429, 500, and 503
                    log.info("Retrying ({d}/{d}) after {d} seconds.", .{ attempt + 1, self.max_retries, backoff });
                    try std.Io.sleep(self.io, .fromNanoseconds(@intFromFloat(backoff * std.time.ns_per_s)), .awake);
                    backoff = if (backoff * 2 <= MAX_RETRY_DELAY) backoff * 2 else MAX_RETRY_DELAY;
                } else {
                    return handleErrorResponse(allocator, result.status, body);
                }
            } else {
                if (ResponseType) |T| {
                    const response: T = try json.deserializeStructWithArena(T, allocator, body);
                    return response;
                } else {
                    return;
                }
            }
        }
        // max_retries must be >= 0 (since it's usize) and loop condition is 0..max_retries+1
        unreachable;
    }

    /// Makes a request and returns the raw response body. Caller owns the returned bytes.
    pub fn requestRaw(self: *const OpenAI, options: OpenAIRequest, max_bytes: usize) ![]u8 {
        const method = options.method;
        const path = options.path;
        const allocator = self.allocator;
        const url_string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, path });
        defer allocator.free(url_string);

        const uri = try std.Uri.parse(url_string);
        var http_client = std.http.Client{ .allocator = allocator, .io = self.io };
        defer http_client.deinit();
        var backoff: f32 = INITIAL_RETRY_DELAY;

        for (0..self.max_retries + 1) |attempt| {
            var req = try std.http.Client.request(&http_client, method, uri, .{
                .headers = self.headers,
                .extra_headers = self.extra_headers,
                .redirect_behavior = .unhandled,
            });
            defer req.deinit();

            if (options.json) |body| {
                req.transfer_encoding = .{ .content_length = body.len };
                var body_writer = try req.sendBodyUnflushed(&.{});
                log.debug("{s}", .{body});
                try body_writer.writer.writeAll(body);
                try body_writer.end();
                try req.connection.?.flush();
            } else {
                try req.sendBodiless();
            }

            var response = try req.receiveHead(&.{});
            var transfer_buffer: [64 * 1024]u8 = undefined;
            const reader = response.reader(&transfer_buffer);
            const body = try reader.allocRemaining(allocator, .limited(max_bytes));

            const status_int = @intFromEnum(response.head.status);
            log.info("{s} - {s} - {d} {s}", .{ @tagName(method), url_string, status_int, response.head.status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt != self.max_retries and status_int >= 429) {
                    allocator.free(body);
                    log.info("Retrying ({d}/{d}) after {d} seconds.", .{ attempt + 1, self.max_retries, backoff });
                    try std.Io.sleep(self.io, .fromNanoseconds(@intFromFloat(backoff * std.time.ns_per_s)), .awake);
                    backoff = if (backoff * 2 <= MAX_RETRY_DELAY) backoff * 2 else MAX_RETRY_DELAY;
                } else {
                    defer allocator.free(body);
                    return handleErrorResponse(allocator, response.head.status, body);
                }
            } else {
                return body;
            }
        }
        unreachable;
    }

    /// Makes a multipart/form-data request to OpenAI. The caller owns `body` and `content_type`.
    pub fn requestMultipart(self: *const OpenAI, options: MultipartRequest, comptime ResponseType: ?type) !if (ResponseType) |T| T else void {
        const allocator = self.allocator;
        const url_string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, options.path });
        defer allocator.free(url_string);

        const uri = try std.Uri.parse(url_string);
        var http_client = std.http.Client{ .allocator = allocator, .io = self.io };
        defer http_client.deinit();
        var headers = self.headers;
        headers.content_type = .{ .override = options.content_type };
        var backoff: f32 = INITIAL_RETRY_DELAY;

        for (0..self.max_retries + 1) |attempt| {
            var response_writer = std.Io.Writer.Allocating.init(allocator);
            defer response_writer.deinit();
            const result = try http_client.fetch(.{
                .location = .{ .uri = uri },
                .method = .POST,
                .payload = options.body,
                .headers = headers,
                .extra_headers = self.extra_headers,
                .redirect_behavior = .unhandled,
                .response_writer = &response_writer.writer,
            });
            const body = try response_writer.toOwnedSlice();
            defer allocator.free(body);

            const status_int = @intFromEnum(result.status);
            log.info("POST - {s} - {d} {s}", .{ url_string, status_int, result.status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt != self.max_retries and status_int >= 429) {
                    log.info("Retrying ({d}/{d}) after {d} seconds.", .{ attempt + 1, self.max_retries, backoff });
                    try std.Io.sleep(self.io, .fromNanoseconds(@intFromFloat(backoff * std.time.ns_per_s)), .awake);
                    backoff = if (backoff * 2 <= MAX_RETRY_DELAY) backoff * 2 else MAX_RETRY_DELAY;
                } else {
                    return handleErrorResponse(allocator, result.status, body);
                }
            } else {
                if (ResponseType) |T| {
                    return json.deserializeStructWithArena(T, allocator, body);
                } else {
                    return;
                }
            }
        }
        unreachable;
    }
};

test "OpenAI Client - usage" {
    const allocator = std.testing.allocator;
    const client = try OpenAI.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .api_key = "my-test-api-key",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings(DEFAULT_USER_AGENT, client.headers.user_agent.override);
}

test "OpenAI Client supports custom User-Agent" {
    const allocator = std.testing.allocator;
    const client = try OpenAI.init(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .api_key = "my-test-api-key",
        .user_agent = "dsabuddy/1.2.3",
    });
    defer client.deinit();

    try std.testing.expectEqualStrings("dsabuddy/1.2.3", client.headers.user_agent.override);
}

test "non-json error responses preserve HTTP status mapping" {
    try std.testing.expectEqual(
        OpenAIError.NotSupported,
        classifyErrorResponse(std.testing.allocator, .forbidden, "error code: 1010"),
    );
}
