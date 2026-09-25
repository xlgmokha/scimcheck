//! Resource management commands: types, list, search, get, create, replace,
//! patch and delete.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Args = @import("args.zig").Args;
const Client = @import("Client.zig");
const j = @import("json.zig");
const output = @import("output.zig");
const urn = @import("check.zig").urn;

pub const Context = struct {
    arena: Allocator,
    io: Io,
    client: *Client,
    args: Args,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
};

const Command = enum { types, list, search, get, create, replace, patch, delete };

/// Stops `--all` against a server that never reports the end of a listing.
const max_pages = 100_000;

pub fn isCommand(name: []const u8) bool {
    return std.meta.stringToEnum(Command, name) != null;
}

/// Runs a resource command and returns the process exit status.
pub fn run(ctx: Context, name: []const u8, positional: []const []const u8) !u8 {
    const cmd = std.meta.stringToEnum(Command, name).?;
    const min: usize, const max: usize = switch (cmd) {
        .types => .{ 0, 0 },
        .list, .search => .{ 0, 1 },
        .create => .{ 1, 1 },
        .get, .replace, .patch, .delete => .{ 1, 2 },
    };
    if (positional.len < min or positional.len > max) {
        try ctx.stderr.print("error: wrong number of arguments for {s}; see 'scimcheck --help'\n", .{name});
        return 2;
    }

    // Reject bad numbers here rather than letting each server word the error.
    if (ctx.args.start_index) |s| _ = try std.fmt.parseInt(i64, s, 10);
    if (ctx.args.count) |s| _ = try std.fmt.parseInt(i64, s, 10);

    const streaming = (cmd == .list or cmd == .search) and (ctx.args.all or positional.len == 0);
    const default_format: output.Format = if (cmd == .types) .table else if (streaming) .jsonl else .json;
    const format = if (ctx.args.output) |o| std.meta.stringToEnum(output.Format, o) orelse {
        try ctx.stderr.print("error: unknown output format '{s}' (json, jsonl, table, ids)\n", .{o});
        return 2;
    } else default_format;
    var printer: output.Printer = .{ .arena = ctx.arena, .out = ctx.stdout, .format = format };

    return switch (cmd) {
        .types => types(ctx, &printer),
        .list, .search => {
            const method: http.Method = if (cmd == .list) .GET else .POST;
            if (positional.len == 0) return everything(ctx, &printer, method);
            const endpoint = try resolve(ctx, positional[0], null);
            if (!ctx.args.all) return single(ctx, &printer, method, try pageTarget(ctx, method, endpoint, null), method == .POST);
            printer.beginList();
            const ok = try listAll(ctx, &printer, method, endpoint, null);
            try printer.finish();
            return if (ok) 0 else 1;
        },
        .get => single(ctx, &printer, .GET, try withQuery(ctx.arena, try resolve(ctx, positional[0], idArg(positional)), ctx.args, false), false),
        .create => single(ctx, &printer, .POST, try resolve(ctx, positional[0], null), true),
        .replace => single(ctx, &printer, .PUT, try resolve(ctx, positional[0], idArg(positional)), true),
        .patch => single(ctx, &printer, .PATCH, try resolve(ctx, positional[0], idArg(positional)), true),
        .delete => single(ctx, &printer, .DELETE, try resolve(ctx, positional[0], idArg(positional)), false),
    };
}

fn idArg(positional: []const []const u8) ?[]const u8 {
    return if (positional.len > 1) positional[1] else null;
}

/// `scimcheck types`: the server's resource types (RFC 7644 §4).
fn types(ctx: Context, printer: *output.Printer) !u8 {
    const res = try ctx.client.get(ctx.arena, "/ResourceTypes");
    if (res.status != .ok) return reportError(ctx, "/ResourceTypes", res);
    const body = res.json(ctx.arena) orelse return reportError(ctx, "/ResourceTypes", res);
    if (printer.format != .table) {
        try printer.document(body);
        try printer.finish();
        return 0;
    }
    var rows: std.ArrayList([]const []const u8) = .empty;
    for (try parseTypes(ctx.arena, body)) |t| {
        try rows.append(ctx.arena, try ctx.arena.dupe([]const u8, &.{ t.name, t.endpoint, t.schema, try std.mem.join(ctx.arena, ",", t.extensions) }));
    }
    try output.writeTable(ctx.arena, ctx.stdout, &.{ "NAME", "ENDPOINT", "SCHEMA", "EXTENSIONS" }, rows.items);
    return 0;
}

/// `scimcheck list` / `search` without a type: every resource of every type.
fn everything(ctx: Context, printer: *output.Printer, method: http.Method) !u8 {
    printer.show_type = true;
    printer.beginList();
    var ok = true;
    if (method == .POST) {
        // RFC 7644 §3.4.3: a search at the server root spans all resource types.
        ok = try listAll(ctx, printer, .POST, "", null);
    } else {
        const resource_types = fetchTypes(ctx) catch return 1;
        for (resource_types) |t| ok = try listAll(ctx, printer, .GET, t.endpoint, t.name) and ok;
    }
    try printer.finish();
    return if (ok) 0 else 1;
}

/// Reads every page of a listing (RFC 7644 §3.4.2.4), printing resources as
/// they arrive. Returns false if the server returned an error.
fn listAll(ctx: Context, printer: *output.Printer, method: http.Method, endpoint: []const u8, type_name: ?[]const u8) !bool {
    var start: i64 = if (ctx.args.start_index) |s| try std.fmt.parseInt(i64, s, 10) else 1;
    var pages: usize = 0;
    while (pages < max_pages) : (pages += 1) {
        const target = try pageTarget(ctx, method, endpoint, start);
        const res = try ctx.client.send(ctx.arena, method, target, .{
            .body = if (method == .POST) try searchRequest(ctx.arena, ctx.args, start) else null,
        });
        if (res.status != .ok) {
            _ = try reportError(ctx, target, res);
            return false;
        }
        const body = res.json(ctx.arena) orelse {
            _ = try reportError(ctx, target, res);
            return false;
        };
        const resources = j.array(j.field(body, "Resources")) orelse &.{};
        for (resources) |r| {
            var resource = r;
            if (type_name) |name| try labelType(ctx.arena, &resource, name);
            try printer.resource(type_name, resource);
        }
        if (resources.len == 0) break;
        start += @intCast(resources.len);
        if (j.integer(j.field(body, "totalResults"))) |total| if (start > total) break;
    }
    return true;
}

/// Sends one request, reports the status on stderr and prints the body.
fn single(ctx: Context, printer: *output.Printer, method: http.Method, target: []const u8, with_body: bool) !u8 {
    const body: ?[]const u8 = if (!with_body) null else switch (method) {
        .PATCH => try patchBody(ctx.arena, ctx.io, ctx.args),
        .POST => if (std.mem.endsWith(u8, target, "/.search")) try searchRequest(ctx.arena, ctx.args, null) else try readBody(ctx.arena, ctx.io, ctx.args),
        else => try readBody(ctx.arena, ctx.io, ctx.args),
    };
    const res = try ctx.client.send(ctx.arena, method, target, .{ .body = body, .if_match = ctx.args.if_match });
    if (@intFromEnum(res.status) >= 400) return reportError(ctx, target, res);

    try ctx.stderr.print("HTTP {d} {s}\n", .{ @intFromEnum(res.status), res.status.phrase() orelse "" });
    if (res.etag) |e| try ctx.stderr.print("ETag: {s}\n", .{e});
    if (res.location) |l| try ctx.stderr.print("Location: {s}\n", .{l});
    try ctx.stderr.flush();
    if (res.json(ctx.arena)) |value| {
        try printer.document(value);
        try printer.finish();
    } else if (res.body.len > 0) {
        try ctx.stdout.writeAll(res.body);
    }
    return 0;
}

// ----------------------------------------------------------------------
// Resource types and target resolution
// ----------------------------------------------------------------------

pub const ResourceType = struct {
    name: []const u8,
    endpoint: []const u8,
    schema: []const u8,
    extensions: []const []const u8,
};

pub fn parseTypes(arena: Allocator, body: Value) ![]ResourceType {
    var result: std.ArrayList(ResourceType) = .empty;
    for (j.array(j.field(body, "Resources")) orelse &.{}) |rt| {
        var extensions: std.ArrayList([]const u8) = .empty;
        for (j.array(j.field(rt, "schemaExtensions")) orelse &.{}) |ext| {
            if (j.string(j.field(ext, "schema"))) |s| try extensions.append(arena, s);
        }
        try result.append(arena, .{
            .name = j.string(j.field(rt, "name")) orelse continue,
            .endpoint = j.string(j.field(rt, "endpoint")) orelse continue,
            .schema = j.string(j.field(rt, "schema")) orelse "",
            .extensions = extensions.items,
        });
    }
    return result.items;
}

/// Matches a resource type by name (`User`), endpoint (`/Users`, `Users`), or
/// the endpoint's last segment, ignoring case.
pub fn findType(resource_types: []const ResourceType, name: []const u8) ?ResourceType {
    const wanted = std.mem.trim(u8, name, "/");
    for (resource_types) |t| {
        const endpoint = std.mem.trim(u8, t.endpoint, "/");
        const last = endpoint[if (std.mem.findScalarLast(u8, endpoint, '/')) |i| i + 1 else 0..];
        if (std.ascii.eqlIgnoreCase(t.name, wanted) or
            std.ascii.eqlIgnoreCase(endpoint, wanted) or
            std.ascii.eqlIgnoreCase(last, wanted)) return t;
    }
    return null;
}

/// Paths that are sent as is without consulting /ResourceTypes.
fn isLiteralPath(first: []const u8) bool {
    const fixed = [_][]const u8{ "ServiceProviderConfig", "ResourceTypes", "Schemas", "Bulk", "Me" };
    const head = std.mem.trimStart(u8, first, "/");
    for (fixed) |f| if (std.ascii.eqlIgnoreCase(head, f) or
        (std.ascii.startsWithIgnoreCase(head, f) and head.len > f.len and head[f.len] == '/')) return true;
    if (std.mem.startsWith(u8, first, "http://") or std.mem.startsWith(u8, first, "https://")) return true;
    // `Users/2819c223` is already a resource path.
    return std.mem.findScalar(u8, std.mem.trimEnd(u8, head, "/"), '/') != null;
}

/// Joins an endpoint and an id into a resource path.
pub fn resourcePath(arena: Allocator, endpoint: []const u8, id: ?[]const u8) ![]const u8 {
    const i = id orelse return endpoint;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, endpoint, "/"), try pathEscape(arena, i) });
}

fn pathEscape(arena: Allocator, s: []const u8) ![]const u8 {
    return Client.queryEscape(arena, s);
}

fn fetchTypes(ctx: Context) ![]ResourceType {
    const res = ctx.client.get(ctx.arena, "/ResourceTypes") catch |err| {
        try ctx.stderr.print("error: GET /ResourceTypes: {s}\n", .{@errorName(err)});
        return err;
    };
    const body = if (res.status == .ok) res.json(ctx.arena) else null;
    if (body == null) {
        _ = try reportError(ctx, "/ResourceTypes", res);
        return error.ResourceTypesUnavailable;
    }
    return parseTypes(ctx.arena, body.?);
}

/// Turns `TYPE [ID]` or a literal path into a request target. Type names are
/// looked up in /ResourceTypes; if the lookup fails or nothing matches, the
/// argument is used as a path relative to the base URL.
fn resolve(ctx: Context, first: []const u8, id: ?[]const u8) ![]const u8 {
    if (isLiteralPath(first)) return resourcePath(ctx.arena, first, id);
    const res = ctx.client.get(ctx.arena, "/ResourceTypes") catch return resourcePath(ctx.arena, first, id);
    const body = (if (res.status == .ok) res.json(ctx.arena) else null) orelse return resourcePath(ctx.arena, first, id);
    const endpoint = if (findType(try parseTypes(ctx.arena, body), first)) |t| t.endpoint else first;
    return resourcePath(ctx.arena, endpoint, id);
}

/// The request target for one page of a listing.
fn pageTarget(ctx: Context, method: http.Method, endpoint: []const u8, start: ?i64) ![]const u8 {
    if (method == .POST) return std.fmt.allocPrint(ctx.arena, "{s}/.search", .{std.mem.trimEnd(u8, endpoint, "/")});
    var args = ctx.args;
    if (start) |s| args.start_index = try std.fmt.allocPrint(ctx.arena, "{d}", .{s});
    return withQuery(ctx.arena, endpoint, args, true);
}

/// Adds `meta.resourceType` when the server leaves it out, so resources from
/// a listing that spans types can be told apart.
fn labelType(arena: Allocator, v: *Value, name: []const u8) !void {
    if (v.* != .object) return;
    if (j.string(j.path(v.*, "meta.resourceType")) != null) return;
    const meta = try v.object.getOrPut(arena, "meta");
    if (!meta.found_existing or meta.value_ptr.* != .object) meta.value_ptr.* = .{ .object = .empty };
    try meta.value_ptr.object.put(arena, "resourceType", .{ .string = name });
}

/// Prints an error response to stderr and returns exit status 1.
fn reportError(ctx: Context, target: []const u8, res: Client.Response) !u8 {
    try ctx.stderr.print("error: {s}: HTTP {d} {s}\n", .{ target, @intFromEnum(res.status), res.status.phrase() orelse "" });
    if (res.json(ctx.arena)) |v| try output.pretty(ctx.stderr, v) else if (res.body.len > 0) try ctx.stderr.print("{s}\n", .{res.body});
    try ctx.stderr.flush();
    return 1;
}

// ----------------------------------------------------------------------
// Request bodies and query strings
// ----------------------------------------------------------------------

/// Appends SCIM query parameters (RFC 7644 §3.4.2) from the flags.
fn withQuery(arena: Allocator, target: []const u8, args: Args, listing: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, target);
    var sep: u8 = if (std.mem.findScalar(u8, target, '?') == null) '?' else '&';
    const params = [_]struct { []const u8, ?[]const u8, bool }{
        .{ "filter", args.filter, true },
        .{ "sortBy", args.sort_by, true },
        .{ "sortOrder", args.sort_order, true },
        .{ "startIndex", args.start_index, true },
        .{ "count", args.count, true },
        .{ "attributes", args.attributes, false },
        .{ "excludedAttributes", args.excluded_attributes, false },
    };
    for (params) |p| {
        const name, const value, const list_only = p;
        const v = value orelse continue;
        if (list_only and !listing) return error.Usage;
        try out.print(arena, "{c}{s}={s}", .{ sep, name, try Client.queryEscape(arena, v) });
        sep = '&';
    }
    return out.items;
}

/// Builds a SearchRequest (RFC 7644 §3.4.3) body from the query flags.
/// `start` overrides --start-index when paging.
fn searchRequest(arena: Allocator, args: Args, start: ?i64) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try w.beginObject();
    try w.objectField("schemas");
    try w.write(&[_][]const u8{urn.search_request});
    const strings = [_]struct { []const u8, ?[]const u8 }{
        .{ "filter", args.filter },
        .{ "sortBy", args.sort_by },
        .{ "sortOrder", args.sort_order },
    };
    for (strings) |p| if (p[1]) |v| {
        try w.objectField(p[0]);
        try w.write(v);
    };
    const lists = [_]struct { []const u8, ?[]const u8 }{
        .{ "attributes", args.attributes },
        .{ "excludedAttributes", args.excluded_attributes },
    };
    for (lists) |p| if (p[1]) |v| {
        try w.objectField(p[0]);
        try w.beginArray();
        var it = std.mem.tokenizeAny(u8, v, ", ");
        while (it.next()) |a| try w.write(a);
        try w.endArray();
    };
    const start_index: ?i64 = start orelse if (args.start_index) |v| try std.fmt.parseInt(i64, v, 10) else null;
    if (start_index) |v| {
        try w.objectField("startIndex");
        try w.write(v);
    }
    if (args.count) |v| {
        try w.objectField("count");
        try w.write(try std.fmt.parseInt(i64, v, 10));
    }
    try w.endObject();
    return out.written();
}

fn readBody(arena: Allocator, io: Io, args: Args) ![]const u8 {
    if (args.data) |d| return d;
    if (args.file) |path| {
        if (!std.mem.eql(u8, path, "-")) return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
    }
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(16 << 20));
}

/// Uses --op/--path/--value to build a one-operation PatchOp (RFC 7644
/// §3.5.2), otherwise reads a full PatchOp body.
fn patchBody(arena: Allocator, io: Io, args: Args) ![]const u8 {
    const op = args.op orelse return readBody(arena, io, args);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"schemas\":[\"{s}\"],\"Operations\":[{{\"op\":{f}", .{ urn.patch_op, std.json.fmt(op, .{}) });
    if (args.op_path) |p| try w.print(",\"path\":{f}", .{std.json.fmt(p, .{})});
    if (args.op_value) |v| {
        // Accept any JSON value; fall back to treating the text as a string.
        if (std.json.validate(arena, v) catch false) {
            try w.print(",\"value\":{s}", .{v});
        } else {
            try w.print(",\"value\":{f}", .{std.json.fmt(v, .{})});
        }
    }
    try w.writeAll("}]}");
    return out.written();
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const test_types = [_]ResourceType{
    .{ .name = "User", .endpoint = "/scim/v2/Users", .schema = urn.user, .extensions = &.{} },
    .{ .name = "Group", .endpoint = "/Groups", .schema = urn.group, .extensions = &.{} },
};

test findType {
    try std.testing.expectEqualStrings("/scim/v2/Users", findType(&test_types, "User").?.endpoint);
    try std.testing.expectEqualStrings("/scim/v2/Users", findType(&test_types, "users").?.endpoint);
    try std.testing.expectEqualStrings("/scim/v2/Users", findType(&test_types, "/scim/v2/Users").?.endpoint);
    try std.testing.expectEqualStrings("/Groups", findType(&test_types, "group").?.endpoint);
    try std.testing.expectEqualStrings("/Groups", findType(&test_types, "/Groups").?.endpoint);
    try std.testing.expect(findType(&test_types, "Device") == null);
}

test isLiteralPath {
    try std.testing.expect(isLiteralPath("ServiceProviderConfig"));
    try std.testing.expect(isLiteralPath("/Schemas/urn:ietf:params:scim:schemas:core:2.0:User"));
    try std.testing.expect(isLiteralPath("Users/2819c223"));
    try std.testing.expect(isLiteralPath("https://example.com/scim/v2/Users/1"));
    try std.testing.expect(!isLiteralPath("User"));
    try std.testing.expect(!isLiteralPath("/Users"));
    try std.testing.expect(!isLiteralPath("SchemasOfMine"));
}

test resourcePath {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("/Groups/e9e30dba", try resourcePath(a, "/Groups/", "e9e30dba"));
    try std.testing.expectEqualStrings("/Users/a%2Fb", try resourcePath(a, "/Users", "a/b"));
    try std.testing.expectEqualStrings("/Users", try resourcePath(a, "/Users", null));
}

test parseTypes {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = try std.json.parseFromSliceLeaky(Value, a,
        \\{"Resources":[{"name":"User","endpoint":"/Users","schema":"urn:u",
        \\  "schemaExtensions":[{"schema":"urn:ext","required":false}]},{"endpoint":"/NoName"}]}
    , .{});
    const parsed = try parseTypes(a, body);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("urn:ext", parsed[0].extensions[0]);
}

test labelType {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a, "{\"id\":\"1\"}", .{});
    try labelType(a, &v, "Device");
    try std.testing.expectEqualStrings("Device", j.string(j.path(v, "meta.resourceType")).?);
    var labelled = try std.json.parseFromSliceLeaky(Value, a, "{\"meta\":{\"resourceType\":\"User\"}}", .{});
    try labelType(a, &labelled, "Other");
    try std.testing.expectEqualStrings("User", j.string(j.path(labelled, "meta.resourceType")).?);
}

test withQuery {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const q = try withQuery(arena_state.allocator(), "Users", .{ .filter = "userName eq \"a b\"", .count = "2" }, true);
    try std.testing.expectEqualStrings("Users?filter=userName%20eq%20%22a%20b%22&count=2", q);
    try std.testing.expectError(error.Usage, withQuery(arena_state.allocator(), "Users/1", .{ .filter = "x" }, false));
}

test patchBody {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "{\"schemas\":[\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"],\"Operations\":[{\"op\":\"replace\",\"path\":\"active\",\"value\":false}]}",
        try patchBody(a, std.testing.io, .{ .op = "replace", .op_path = "active", .op_value = "false" }),
    );
    try std.testing.expectEqualStrings(
        "{\"schemas\":[\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"],\"Operations\":[{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"Babs\"}]}",
        try patchBody(a, std.testing.io, .{ .op = "replace", .op_path = "displayName", .op_value = "Babs" }),
    );
}

test searchRequest {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "{\"schemas\":[\"urn:ietf:params:scim:api:messages:2.0:SearchRequest\"],\"filter\":\"userName pr\",\"attributes\":[\"userName\",\"emails\"],\"startIndex\":11,\"count\":5}",
        try searchRequest(arena_state.allocator(), .{ .filter = "userName pr", .attributes = "userName,emails", .count = "5" }, 11),
    );
}
