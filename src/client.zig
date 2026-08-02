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
const MAX_SERVER_RETRY_DELAY = 60;
pub const DEFAULT_USER_AGENT = "openai-zig/0.2.4";

pub const AbortController = struct {
    state: AbortState = .{},

    pub fn init() AbortController {
        return .{};
    }

    /// Cancels the associated stream, if one is currently attached.
    ///
    /// This method is thread-safe and may be called while another thread/task is
    /// blocked in `Stream.next`. Cancellation uses the `std.Io` supplied to
    /// `OpenAI.init` for the active request.
    ///
    /// The controller is one-shot: after `abort` is called, it remains aborted
    /// and should not be reused for a new request.
    pub fn abort(self: *AbortController) void {
        self.state.abort();
    }

    pub fn isAborted(self: *const AbortController) bool {
        return self.state.aborted();
    }
};

const AbortState = struct {
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active: std.atomic.Value(?*std.http.Client.Connection) = std.atomic.Value(?*std.http.Client.Connection).init(null),

    fn aborted(self: *const AbortState) bool {
        return self.canceled.load(.acquire);
    }

    fn abort(self: *AbortState) void {
        self.canceled.store(true, .release);
        self.wake();
    }

    fn attach(self: *AbortState, connection: *std.http.Client.Connection) void {
        const old = self.active.swap(connection, .acq_rel);
        std.debug.assert(old == null);
        if (self.aborted()) {
            self.wake();
        }
    }

    fn detach(self: *AbortState, connection: *std.http.Client.Connection) void {
        _ = self.active.cmpxchgStrong(connection, null, .acq_rel, .acquire);
    }

    fn wake(self: *AbortState) void {
        const connection = self.active.swap(null, .acq_rel) orelse return;
        connection.stream_reader.stream.shutdown(connection.client.io, .both) catch {};
    }
};

fn checkCanceled(request: *std.http.Client.Request, controller: ?*AbortController) error{Canceled}!void {
    const c = controller orelse return;
    if (!c.isAborted()) return;
    if (request.connection) |connection| {
        connection.closing = true;
    }
    return error.Canceled;
}

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
        decompress: *std.http.Decompress,
        decompress_buffer: []u8,
        controller: *AbortController,
        owns_controller: bool,

        pub fn init(allocator: std.mem.Allocator, http_client: *std.http.Client, request: *std.http.Client.Request, response: *std.http.Client.Response, controller: ?*AbortController, attached: bool) !@This() {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer allocator.destroy(arena);

            const transfer_buffer = try allocator.alloc(u8, 64 * 1024);
            errdefer allocator.free(transfer_buffer);

            const owns_controller = controller == null;
            const stream_controller = controller orelse controller: {
                const owned = try allocator.create(AbortController);
                owned.* = .{};
                break :controller owned;
            };
            errdefer if (owns_controller) allocator.destroy(stream_controller);

            if (!attached) {
                stream_controller.state.attach(request.connection.?);
            }

            const decompress = try allocator.create(std.http.Decompress);
            errdefer allocator.destroy(decompress);

            const decompress_buffer = try allocator.alloc(u8, try decompressionBufferSize(response.head.content_encoding));
            errdefer allocator.free(decompress_buffer);

            return .{
                .arena = arena,
                .request = request,
                .client = http_client,
                .reader = response.readerDecompressing(transfer_buffer, decompress, decompress_buffer),
                .transfer_buffer = transfer_buffer,
                .decompress = decompress,
                .decompress_buffer = decompress_buffer,
                .controller = stream_controller,
                .owns_controller = owns_controller,
            };
        }

        pub fn deinit(self: *@This()) void {
            const allocator = self.arena.child_allocator;
            if (self.request.connection) |connection| {
                self.controller.state.detach(connection);
            }
            allocator.free(self.transfer_buffer);
            allocator.free(self.decompress_buffer);
            allocator.destroy(self.decompress);
            self.arena.deinit();
            self.request.deinit();
            self.client.deinit();
            allocator.destroy(self.request);
            allocator.destroy(self.client);
            if (self.owns_controller) {
                allocator.destroy(self.controller);
            }
            allocator.destroy(self.arena);
        }

        /// Cancels this stream. `next` returns `error.Canceled` once socket
        /// shutdown wakes the pending read.
        pub fn abort(self: *@This()) void {
            self.controller.abort();
        }

        pub fn isAborted(self: *const @This()) bool {
            return self.controller.isAborted();
        }

        fn checkCanceled(self: *@This()) error{Canceled}!void {
            if (!self.isAborted()) return;
            if (self.request.connection) |connection| {
                connection.closing = true;
            }
            return error.Canceled;
        }

        fn parseEvent(self: *@This(), data: []const u8) !?T {
            if (comptime @hasDecl(T, "parseSseData")) {
                return try T.parseSseData(self.arena.allocator(), data);
            }
            return try std.json.parseFromSliceLeaky(T, self.arena.allocator(), data, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
        }

        pub fn next(self: *@This()) !?T {
            try self.checkCanceled();
            while (self.reader.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => {
                    try self.checkCanceled();
                    return err;
                },
                else => |e| return e,
            }) |line| {
                if (std.mem.trim(u8, line, " \t\r\n").len != 0) {
                    var it = std.mem.splitSequence(u8, line, "data:");
                    _ = it.next();
                    const stripped = std.mem.trim(u8, it.rest(), " \t\r\n");
                    if (stripped.len == 0) continue;
                    if (std.mem.eql(u8, "[DONE]", stripped)) return null;
                    if (try self.parseEvent(stripped)) |event| return event;
                }
            }
            try self.checkCanceled();
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

fn decompressionBufferSize(encoding: std.http.ContentEncoding) !usize {
    return switch (encoding) {
        .identity => 0,
        .deflate, .gzip => std.compress.flate.max_window_len,
        .zstd => std.compress.zstd.default_window_len,
        .compress => error.UnsupportedCompressionMethod,
    };
}

fn allocResponseBody(allocator: std.mem.Allocator, response: *std.http.Client.Response, max_bytes: usize) ![]u8 {
    var transfer_buffer: [64 * 1024]u8 = undefined;
    const decompress_buffer = try allocator.alloc(u8, try decompressionBufferSize(response.head.content_encoding));
    defer allocator.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(allocator, .limited(max_bytes));
}

fn isRetryableStatus(status: std.http.Status) bool {
    return switch (status) {
        .request_timeout,
        .conflict,
        .too_many_requests,
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        => true,
        else => false,
    };
}

fn retryAfterSeconds(head: std.http.Client.Response.Head) ?f32 {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        const divisor: f32 = if (std.ascii.eqlIgnoreCase(header.name, "retry-after-ms"))
            1000
        else if (std.ascii.eqlIgnoreCase(header.name, "retry-after"))
            1
        else
            continue;
        const parsed = std.fmt.parseFloat(f32, header.value) catch continue;
        const seconds = parsed / divisor;
        if (std.math.isFinite(seconds) and seconds >= 0 and seconds <= MAX_SERVER_RETRY_DELAY) return seconds;
    }
    return null;
}

fn waitBeforeRetry(self: *const OpenAI, attempt: usize, retry_after: ?f32, backoff: f32) !f32 {
    const delay = retry_after orelse backoff;
    log.info("Retrying ({d}/{d}) after {d} seconds.", .{ attempt + 1, self.max_retries, delay });
    try std.Io.sleep(self.io, .fromNanoseconds(@intFromFloat(delay * std.time.ns_per_s)), .awake);
    return if (backoff * 2 <= MAX_RETRY_DELAY) backoff * 2 else MAX_RETRY_DELAY;
}

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
    /// Your OpenAI API key. If null and `environ_map` is provided, reads `OPENAI_API_KEY` from it.
    api_key: ?[]const u8 = null,
    /// Your OpenAI base URL. If null, reads `OPENAI_BASE_URL` from `environ_map`, then defaults to `"https://api.openai.com/v1"`.
    base_url: ?[]const u8 = null,
    /// Your OpenAI organization ID. If null and `environ_map` is provided, reads `OPENAI_ORG_ID` from it.
    organization: ?[]const u8 = null,
    /// Your OpenAI project ID. If null and `environ_map` is provided, reads `OPENAI_PROJECT_ID` from it.
    project: ?[]const u8 = null,
    /// The maximum number of retries the client will attempt. Defaults to `3`.
    max_retries: usize = 3,
    /// User-Agent header sent with every request. Defaults to `openai-zig/0.2.4`.
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
    ///
    /// All request I/O, including stream abort wakeups, uses the supplied `io`.
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
        self.models.deinit();
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

    pub const StreamingMultipartRequest = struct {
        path: []const u8,
        content_type: []const u8,
        content_length: u64,
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
        return self.requestStreamInner(options, ResponseType, null);
    }

    /// Like `requestStream`, but attaches a caller-owned abort controller that
    /// can cancel a blocked `Stream.next` call from another task/thread.
    ///
    /// The controller must outlive the returned stream and must not be copied
    /// while the stream is using it.
    pub fn requestStreamAbortable(self: *const OpenAI, options: OpenAIRequest, comptime ResponseType: type, controller: *AbortController) !Stream(ResponseType) {
        return self.requestStreamInner(options, ResponseType, controller);
    }

    fn requestStreamInner(self: *const OpenAI, options: OpenAIRequest, comptime ResponseType: type, controller: ?*AbortController) !Stream(ResponseType) {
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
        var attached = false;
        errdefer if (attached) {
            if (controller) |c| {
                if (req.connection) |connection| {
                    c.state.detach(connection);
                }
            }
        };

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            req.* = try std.http.Client.request(http_client, method, uri, .{
                .headers = self.headers,
                .extra_headers = self.extra_headers,
                .redirect_behavior = .unhandled,
            });
            if (controller) |c| {
                c.state.attach(req.connection.?);
                attached = true;
            }

            if (options.json) |body| {
                req.transfer_encoding = .{ .content_length = body.len };
                var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
                    try checkCanceled(req, controller);
                    return err;
                };
                log.debug("{s}", .{body});
                body_writer.writer.writeAll(body) catch |err| {
                    try checkCanceled(req, controller);
                    return err;
                };
                body_writer.end() catch |err| {
                    try checkCanceled(req, controller);
                    return err;
                };
                req.connection.?.flush() catch |err| {
                    try checkCanceled(req, controller);
                    return err;
                };
            } else {
                req.sendBodiless() catch |err| {
                    try checkCanceled(req, controller);
                    return err;
                };
            }
            var response = req.receiveHead(&.{}) catch |err| {
                try checkCanceled(req, controller);
                return err;
            };
            const retry_after = retryAfterSeconds(response.head);
            const status_int = @intFromEnum(response.head.status);
            log.info("{s} - {s} - {d} {s}", .{ @tagName(method), url_string, status_int, response.head.status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt < self.max_retries and isRetryableStatus(response.head.status)) {
                    backoff = try waitBeforeRetry(self, attempt, retry_after, backoff);
                    try checkCanceled(req, controller);
                    if (attached) {
                        if (controller) |c| {
                            if (req.connection) |connection| {
                                c.state.detach(connection);
                            }
                        }
                        attached = false;
                    }
                    req.deinit();
                } else {
                    const body = try allocResponseBody(allocator, &response, 1024 * 1024);
                    defer allocator.free(body);
                    return handleErrorResponse(allocator, response.head.status, body);
                }
            } else {
                const stream = try Stream(ResponseType).init(allocator, http_client, req, &response, controller, attached);
                attached = false;
                return stream;
            }
        }
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
    /// Note that the `ResponseType` _must_ have a field called `arena` of type `json.Arena` (or you will get a @compileError).
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

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var req = try std.http.Client.request(&client, method, uri, .{
                .headers = self.headers,
                .extra_headers = self.extra_headers,
                .redirect_behavior = .unhandled,
            });
            defer req.deinit();

            if (options.json) |request_body| {
                req.transfer_encoding = .{ .content_length = request_body.len };
                var body_writer = try req.sendBodyUnflushed(&.{});
                log.debug("{s}", .{request_body});
                try body_writer.writer.writeAll(request_body);
                try body_writer.end();
                try req.connection.?.flush();
            } else {
                try req.sendBodiless();
            }

            var raw_response = try req.receiveHead(&.{});
            const retry_after = retryAfterSeconds(raw_response.head);
            const body = try allocResponseBody(allocator, &raw_response, std.math.maxInt(usize));
            defer allocator.free(body);

            const status = raw_response.head.status;
            const status_int = @intFromEnum(status);
            log.info("{s} - {s} - {d} {s}", .{ @tagName(method), url_string, status_int, status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt < self.max_retries and isRetryableStatus(status)) {
                    backoff = try waitBeforeRetry(self, attempt, retry_after, backoff);
                } else {
                    return handleErrorResponse(allocator, status, body);
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

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
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
            const retry_after = retryAfterSeconds(response.head);
            const body = try allocResponseBody(allocator, &response, max_bytes);

            const status_int = @intFromEnum(response.head.status);
            log.info("{s} - {s} - {d} {s}", .{ @tagName(method), url_string, status_int, response.head.status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt < self.max_retries and isRetryableStatus(response.head.status)) {
                    allocator.free(body);
                    backoff = try waitBeforeRetry(self, attempt, retry_after, backoff);
                } else {
                    defer allocator.free(body);
                    return handleErrorResponse(allocator, response.head.status, body);
                }
            } else {
                return body;
            }
        }
    }

    /// Makes a multipart/form-data request to OpenAI.
    pub fn requestMultipart(
        self: *const OpenAI,
        options: MultipartRequest,
        comptime ResponseType: ?type,
    ) !if (ResponseType) |T| T else void {
        return self.requestMultipartStream(.{
            .path = options.path,
            .content_type = options.content_type,
            .content_length = options.body.len,
        }, options.body, writeMultipartSlice, ResponseType);
    }

    /// Makes a streaming multipart/form-data request to OpenAI.
    pub fn requestMultipartStream(
        self: *const OpenAI,
        options: StreamingMultipartRequest,
        context: anytype,
        comptime writeBody: anytype,
        comptime ResponseType: ?type,
    ) !if (ResponseType) |T| T else void {
        const allocator = self.allocator;
        const url_string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, options.path });
        defer allocator.free(url_string);

        const uri = try std.Uri.parse(url_string);
        var http_client = std.http.Client{ .allocator = allocator, .io = self.io };
        defer http_client.deinit();
        var headers = self.headers;
        headers.content_type = .{ .override = options.content_type };
        var backoff: f32 = INITIAL_RETRY_DELAY;

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var req = try std.http.Client.request(&http_client, .POST, uri, .{
                .headers = headers,
                .extra_headers = self.extra_headers,
                .redirect_behavior = .unhandled,
            });
            defer req.deinit();

            req.transfer_encoding = .{ .content_length = options.content_length };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try writeBody(context, &body_writer.writer);
            try body_writer.end();
            try req.connection.?.flush();

            var response = try req.receiveHead(&.{});
            const retry_after = retryAfterSeconds(response.head);
            const body = try allocResponseBody(allocator, &response, std.math.maxInt(usize));
            defer allocator.free(body);

            const status_int = @intFromEnum(response.head.status);
            log.info("POST - {s} - {d} {s}", .{ url_string, status_int, response.head.status.phrase() orelse "Unknown" });
            if (status_int < 200 or status_int >= 300) {
                if (attempt < self.max_retries and isRetryableStatus(response.head.status)) {
                    backoff = try waitBeforeRetry(self, attempt, retry_after, backoff);
                } else {
                    return handleErrorResponse(allocator, response.head.status, body);
                }
            } else {
                if (ResponseType) |T| {
                    return json.deserializeStructWithArena(T, allocator, body);
                } else {
                    return;
                }
            }
        }
    }
};

fn writeMultipartSlice(body: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll(body);
}

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

test "decompression buffers match supported encodings" {
    try std.testing.expectEqual(@as(usize, 0), try decompressionBufferSize(.identity));
    try std.testing.expectEqual(@as(usize, std.compress.flate.max_window_len), try decompressionBufferSize(.gzip));
    try std.testing.expectEqual(@as(usize, std.compress.flate.max_window_len), try decompressionBufferSize(.deflate));
    try std.testing.expectEqual(@as(usize, std.compress.zstd.default_window_len), try decompressionBufferSize(.zstd));
    try std.testing.expectError(error.UnsupportedCompressionMethod, decompressionBufferSize(.compress));
}

test "retry policy includes only transient statuses" {
    try std.testing.expect(isRetryableStatus(.request_timeout));
    try std.testing.expect(isRetryableStatus(.conflict));
    try std.testing.expect(isRetryableStatus(.too_many_requests));
    try std.testing.expect(isRetryableStatus(.internal_server_error));
    try std.testing.expect(isRetryableStatus(.bad_gateway));
    try std.testing.expect(isRetryableStatus(.service_unavailable));
    try std.testing.expect(isRetryableStatus(.gateway_timeout));
    try std.testing.expect(!isRetryableStatus(.request_header_fields_too_large));
    try std.testing.expect(!isRetryableStatus(.not_implemented));
}

test "retry delay honors numeric response headers" {
    const milliseconds = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 429 Too Many Requests\r\nRetry-After-Ms: 1250\r\n\r\n",
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), retryAfterSeconds(milliseconds).?, 0.001);

    const seconds = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 2\r\n\r\n",
    );
    try std.testing.expectApproxEqAbs(@as(f32, 2), retryAfterSeconds(seconds).?, 0.001);

    const excessive = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 3600\r\n\r\n",
    );
    try std.testing.expect(retryAfterSeconds(excessive) == null);
}
