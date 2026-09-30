//! A thin SCIM-aware wrapper around `std.http.Client`.
//!
//! Every request resolves a path against the service provider's base URL,
//! sends the SCIM media type, attaches the bearer token and collects the
//! response status, the headers SCIM cares about, and the body.
const Client = @This();

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;

pub const media_type = "application/scim+json";

http_client: http.Client,
/// Base URL of the service provider, without a trailing slash,
/// e.g. `https://example.com/scim/v2`.
base_url: []const u8,
/// Value of the `Authorization` header, e.g. `Bearer abc123`.
authorization: ?[]const u8,
/// When set, every request and response is echoed here.
trace: ?*Io.Writer = null,

pub const Options = struct {
    body: ?[]const u8 = null,
    /// Send the `Authorization` header. Disabled to check that the
    /// service provider rejects anonymous requests.
    authenticate: bool = true,
    /// Sends this `Authorization` value instead of the configured one.
    authorization: ?[]const u8 = null,
    if_match: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
    content_type: []const u8 = media_type,
    accept: []const u8 = media_type ++ ", application/json",
};

pub const Response = struct {
    status: http.Status,
    content_type: ?[]const u8 = null,
    location: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    www_authenticate: ?[]const u8 = null,
    content_location: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    body: []const u8,

    /// Parses the body as JSON. Returns null when the body is empty or not JSON.
    pub fn json(r: Response, arena: Allocator) ?std.json.Value {
        if (std.mem.trim(u8, r.body, " \t\r\n").len == 0) return null;
        return std.json.parseFromSliceLeaky(std.json.Value, arena, r.body, .{}) catch null;
    }

    pub fn isScimMediaType(r: Response) bool {
        const ct = r.content_type orelse return false;
        const end = std.mem.findScalar(u8, ct, ';') orelse ct.len;
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, ct[0..end], " "), media_type);
    }
};

pub fn init(gpa: Allocator, io: Io, base_url: []const u8, authorization: ?[]const u8) Client {
    return .{
        .http_client = .{ .allocator = gpa, .io = io },
        .base_url = std.mem.trimEnd(u8, base_url, "/"),
        .authorization = authorization,
    };
}

pub fn deinit(c: *Client) void {
    c.http_client.deinit();
}

/// Resolves `target` against the base URL. Absolute URLs are returned as is,
/// which lets callers follow `meta.location` and `Location` headers.
pub fn resolve(c: *const Client, arena: Allocator, target: []const u8) ![]const u8 {
    if (isAbsolute(target)) return target;
    // A server may return locations relative to its host, e.g. `/scim/v2/Users/1`.
    // Resolve those against the origin rather than the base path.
    if (c.isUnderBasePath(target)) {
        const origin = c.base_url[0 .. c.base_url.len - c.basePath().len];
        return std.fmt.allocPrint(arena, "{s}{s}", .{ origin, target });
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ c.base_url, std.mem.trimStart(u8, target, "/") });
}

/// Reports whether `target` is an absolute `http` or `https` URL.
pub fn isAbsolute(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://");
}

/// The path of the base URL, e.g. `/scim/v2`; empty when the base URL has no path.
pub fn basePath(c: *const Client) []const u8 {
    const scheme_end = (std.mem.find(u8, c.base_url, "://") orelse 0) + 3;
    const i = std.mem.findScalarPos(u8, c.base_url, scheme_end, '/') orelse return "";
    return c.base_url[i..];
}

/// Reports whether `target` is a host-relative path under the base path, e.g. `/scim/v2/Users/1`.
pub fn isUnderBasePath(c: *const Client, target: []const u8) bool {
    const base_path = c.basePath();
    return base_path.len > 0 and std.mem.startsWith(u8, target, base_path) and
        (target.len == base_path.len or target[base_path.len] == '/' or target[base_path.len] == '?');
}

pub fn get(c: *Client, arena: Allocator, target: []const u8) !Response {
    return c.send(arena, .GET, target, .{});
}

pub fn send(c: *Client, arena: Allocator, method: http.Method, target: []const u8, options: Options) !Response {
    const url = try c.resolve(arena, target);
    const uri = try std.Uri.parse(url);

    var extra: std.ArrayList(http.Header) = .empty;
    try extra.append(arena, .{ .name = "Accept", .value = options.accept });
    if (options.if_match) |v| try extra.append(arena, .{ .name = "If-Match", .value = v });
    if (options.if_none_match) |v| try extra.append(arena, .{ .name = "If-None-Match", .value = v });

    const authorization: http.Client.Request.Headers.Value = if (options.authorization) |a|
        .{ .override = a }
    else if (!options.authenticate)
        .omit
    else if (c.authorization) |a| .{ .override = a } else .omit;

    if (c.trace) |w| {
        try w.print("> {s} {s}\n", .{ @tagName(method), url });
        if (options.body) |b| try w.print("{s}{s}\n", .{ b[0..@min(b.len, 4096)], if (b.len > 4096) "..." else "" });
        try w.flush();
    }

    var req = try c.http_client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = authorization,
            .user_agent = .{ .override = "scimcheck" },
            .accept_encoding = .omit,
            .content_type = if (options.body != null) .{ .override = options.content_type } else .omit,
        },
        .extra_headers = extra.items,
    });
    defer req.deinit();

    if (options.body) |body| {
        try req.sendBodyComplete(try arena.dupe(u8, body));
    } else {
        try req.sendBodiless();
    }

    var response = try req.receiveHead(&.{});

    // Header slices point into the connection buffer and are invalidated
    // once the body is read, so copy what we need first.
    var result: Response = .{ .status = response.head.status, .body = "" };
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            result.content_type = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "location")) {
            result.location = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "etag")) {
            result.etag = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
            result.www_authenticate = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-location")) {
            result.content_location = try arena.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "allow")) {
            result.allow = try arena.dupe(u8, h.value);
        }
    }

    // 204 and 304 responses never carry a body (RFC 9110 §6.4.1). Asking
    // for a body reader here would read until the kept-alive connection
    // closes, i.e. hang.
    if (result.status != .no_content and result.status != .not_modified) {
        var body: Io.Writer.Allocating = .init(arena);
        const reader = response.reader(&.{});
        _ = reader.streamRemaining(&body.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        result.body = body.written();
    } else {
        // Tell `Request.deinit` the message is complete so it does not try
        // to drain a body and the connection can be reused.
        req.reader.state = .ready;
    }

    if (c.trace) |w| {
        try w.print("< {d} {s}\n", .{ @intFromEnum(result.status), result.status.phrase() orelse "" });
        if (result.etag) |e| try w.print("< ETag: {s}\n", .{e});
        if (result.location) |l| try w.print("< Location: {s}\n", .{l});
        if (result.body.len > 0) try w.print("{s}\n", .{result.body});
        try w.writeAll("\n");
        try w.flush();
    }

    return result;
}

/// Percent-encodes `s` for use as a query parameter value.
pub fn queryEscape(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(arena, ch);
        } else {
            try out.print(arena, "%{X:0>2}", .{ch});
        }
    }
    return out.items;
}

test resolve {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c = Client.init(std.testing.allocator, std.testing.io, "http://localhost:8080/scim/v2/", null);
    try std.testing.expectEqualStrings("http://localhost:8080/scim/v2", c.base_url);
    try std.testing.expectEqualStrings("http://localhost:8080/scim/v2/Users", try c.resolve(arena, "Users"));
    try std.testing.expectEqualStrings("http://localhost:8080/scim/v2/Users", try c.resolve(arena, "/Users"));
    try std.testing.expectEqualStrings("http://localhost:8080/scim/v2/Users/1", try c.resolve(arena, "/scim/v2/Users/1"));
    try std.testing.expectEqualStrings("https://other/x", try c.resolve(arena, "https://other/x"));

    const root = Client.init(std.testing.allocator, std.testing.io, "http://localhost:8080", null);
    try std.testing.expectEqualStrings("http://localhost:8080/Users", try root.resolve(arena, "/Users"));
}

test isUnderBasePath {
    const c = Client.init(std.testing.allocator, std.testing.io, "http://localhost:8080/scim/v2", null);
    try std.testing.expectEqualStrings("/scim/v2", c.basePath());
    try std.testing.expect(c.isUnderBasePath("/scim/v2/Users"));
    try std.testing.expect(c.isUnderBasePath("/scim/v2"));
    try std.testing.expect(!c.isUnderBasePath("/Users"));
    try std.testing.expect(!c.isUnderBasePath("/scim/v2Users"));

    const root = Client.init(std.testing.allocator, std.testing.io, "http://localhost:8080", null);
    try std.testing.expectEqualStrings("", root.basePath());
    try std.testing.expect(!root.isUnderBasePath("/Users"));
}

test queryEscape {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "userName%20eq%20%22bjensen%22",
        try queryEscape(arena_state.allocator(), "userName eq \"bjensen\""),
    );
}

test "Response.isScimMediaType" {
    const r: Response = .{ .status = .ok, .body = "", .content_type = "application/scim+json; charset=utf-8" };
    try std.testing.expect(r.isScimMediaType());
    const j: Response = .{ .status = .ok, .body = "", .content_type = "application/json" };
    try std.testing.expect(!j.isScimMediaType());
}
