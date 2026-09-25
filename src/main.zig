const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Client = @import("Client.zig");
const check = @import("check.zig");

const version = "0.1.0";

const usage =
    \\scimcheck - test and manage SCIM 2.0 service providers (RFC 7643, RFC 7644)
    \\
    \\Usage:
    \\  scimcheck [options] check [--only SECTIONS] [--keep]
    \\  scimcheck [options] get <path> [--attributes A] [--excluded-attributes A]
    \\  scimcheck [options] list <endpoint> [--filter F] [--sort-by A] [--sort-order O]
    \\                                      [--start-index N] [--count N] [--attributes A]
    \\  scimcheck [options] search <endpoint> [same flags as list]
    \\  scimcheck [options] create <endpoint> [--data JSON | --file PATH]
    \\  scimcheck [options] replace <path> [--data JSON | --file PATH] [--if-match ETAG]
    \\  scimcheck [options] patch <path> [--data JSON | --file PATH | --op OP [--path P] [--value JSON]]
    \\  scimcheck [options] delete <path> [--if-match ETAG]
    \\
    \\Options:
    \\  -u, --url URL      Base URL of the service provider (env SCIM_URL)
    \\  -t, --token TOKEN  Bearer token (env SCIM_TOKEN)
    \\  -v, --verbose      Print every HTTP request and response to stderr
    \\  -h, --help         Show this help
    \\      --version      Show the version
    \\
    \\Check sections (for --only, comma separated):
    \\  auth, errors, users, attributes, filter, pagination, sort, patch, etag, groups, bulk
    \\
    \\Resource bodies are read from --data, --file, or stdin. Paths are relative
    \\to the base URL, e.g. Users, Users/2819c223, ServiceProviderConfig.
    \\
    \\Examples:
    \\  scimcheck -u http://localhost:8080/scim/v2 -t secret check
    \\  scimcheck list Users --filter 'userName sw "b"' --count 10
    \\  echo '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:User"],"userName":"bjensen"}' | scimcheck create Users
    \\  scimcheck patch Users/2819c223 --op replace --path active --value false
    \\
;

const Args = struct {
    url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    verbose: bool = false,
    positional: std.ArrayList([]const u8) = .empty,
    only: ?[]const u8 = null,
    keep: bool = false,
    data: ?[]const u8 = null,
    file: ?[]const u8 = null,
    if_match: ?[]const u8 = null,
    op: ?[]const u8 = null,
    op_path: ?[]const u8 = null,
    op_value: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    sort_by: ?[]const u8 = null,
    sort_order: ?[]const u8 = null,
    start_index: ?[]const u8 = null,
    count: ?[]const u8 = null,
    attributes: ?[]const u8 = null,
    excluded_attributes: ?[]const u8 = null,
};

const Flag = struct { []const u8, []const u8, ?[]const u8 };

/// Flags that take a value: long name, Args field, short alias.
const value_flags = [_]Flag{
    .{ "--url", "url", "-u" },
    .{ "--token", "token", "-t" },
    .{ "--only", "only", null },
    .{ "--data", "data", "-d" },
    .{ "--file", "file", "-f" },
    .{ "--if-match", "if_match", null },
    .{ "--op", "op", null },
    .{ "--path", "op_path", null },
    .{ "--value", "op_value", null },
    .{ "--filter", "filter", null },
    .{ "--sort-by", "sort_by", null },
    .{ "--sort-order", "sort_order", null },
    .{ "--start-index", "start_index", null },
    .{ "--count", "count", null },
    .{ "--attributes", "attributes", null },
    .{ "--excluded-attributes", "excluded_attributes", null },
};

const UsageError = error{Usage};

fn parseArgs(arena: Allocator, argv: []const []const u8, stderr: *Io.Writer) !Args {
    var args: Args = .{};
    var i: usize = 0;
    next: while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.writeAll(usage);
            try stderr.flush();
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--version")) {
            try stderr.print("scimcheck {s}\n", .{version});
            try stderr.flush();
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep")) {
            args.keep = true;
            continue;
        }
        inline for (value_flags) |flag| {
            const long, const field, const short = flag;
            var value: ?[]const u8 = null;
            if (std.mem.eql(u8, arg, long) or (short != null and std.mem.eql(u8, arg, short.?))) {
                i += 1;
                if (i >= argv.len) {
                    try stderr.print("error: {s} needs a value\n", .{long});
                    return error.Usage;
                }
                value = argv[i];
            } else if (std.mem.startsWith(u8, arg, long ++ "=")) {
                value = arg[long.len + 1 ..];
            }
            if (value) |v| {
                @field(args, field) = v;
                continue :next;
            }
        }
        if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            try stderr.print("error: unknown option {s}\n", .{arg});
            return error.Usage;
        }
        try args.positional.append(arena, arg);
    }
    return args;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(arena, argv[1..], stderr) catch |err| switch (err) {
        error.Usage => {
            try stderr.writeAll("run 'scimcheck --help' for usage\n");
            return 2;
        },
        else => |e| return e,
    };

    if (args.positional.items.len == 0) {
        try stderr.writeAll(usage);
        return 2;
    }

    const url = args.url orelse init.environ_map.get("SCIM_URL") orelse {
        try stderr.writeAll("error: set the service provider URL with --url or SCIM_URL\n");
        return 2;
    };
    const token = args.token orelse init.environ_map.get("SCIM_TOKEN");
    const authorization = if (token) |t| try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) else null;

    var client: Client = .init(init.gpa, io, url, authorization);
    defer client.deinit();
    if (args.verbose) client.trace = stderr;

    const command = args.positional.items[0];
    const rest = args.positional.items[1..];

    if (std.mem.eql(u8, command, "check")) {
        var options: check.Options = .{ .keep = args.keep };
        if (args.only) |only| {
            options.only = .initEmpty();
            var it = std.mem.tokenizeAny(u8, only, ", ");
            while (it.next()) |name| {
                const section = std.meta.stringToEnum(check.Section, name) orelse {
                    try stderr.print("error: unknown section '{s}'\n", .{name});
                    return 2;
                };
                options.only.insert(section);
            }
        }
        var suite: check.Suite = .init(arena, io, &client, stdout, options);
        const summary = suite.run();
        return if (summary.failed > 0) 1 else 0;
    }

    const Command = enum { get, list, search, create, replace, patch, delete };
    const cmd = std.meta.stringToEnum(Command, command) orelse {
        try stderr.print("error: unknown command '{s}'\n", .{command});
        return 2;
    };
    if (rest.len != 1) {
        try stderr.print("error: {s} takes exactly one path argument\n", .{command});
        return 2;
    }
    const target = rest[0];

    const res = switch (cmd) {
        .get => try client.send(arena, .GET, try withQuery(arena, target, args, false), .{}),
        .list => try client.send(arena, .GET, try withQuery(arena, target, args, true), .{}),
        .search => try client.send(arena, .POST, try std.fmt.allocPrint(arena, "{s}/.search", .{std.mem.trimEnd(u8, target, "/")}), .{
            .body = try searchRequest(arena, args),
        }),
        .create => try client.send(arena, .POST, target, .{ .body = try readBody(arena, io, args) }),
        .replace => try client.send(arena, .PUT, target, .{ .body = try readBody(arena, io, args), .if_match = args.if_match }),
        .patch => try client.send(arena, .PATCH, target, .{ .body = try patchBody(arena, io, args), .if_match = args.if_match }),
        .delete => try client.send(arena, .DELETE, target, .{ .if_match = args.if_match }),
    };

    try stderr.print("HTTP {d} {s}\n", .{ @intFromEnum(res.status), res.status.phrase() orelse "" });
    if (res.etag) |e| try stderr.print("ETag: {s}\n", .{e});
    if (res.location) |l| try stderr.print("Location: {s}\n", .{l});
    try stderr.flush();
    if (res.json(arena)) |value| {
        try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else if (res.body.len > 0) {
        try stdout.writeAll(res.body);
    }
    return if (@intFromEnum(res.status) >= 400) 1 else 0;
}

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
fn searchRequest(arena: Allocator, args: Args) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try w.beginObject();
    try w.objectField("schemas");
    try w.write(&[_][]const u8{check.urn.search_request});
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
    const numbers = [_]struct { []const u8, ?[]const u8 }{
        .{ "startIndex", args.start_index },
        .{ "count", args.count },
    };
    for (numbers) |p| if (p[1]) |v| {
        try w.objectField(p[0]);
        try w.write(try std.fmt.parseInt(i64, v, 10));
    };
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
    try w.print("{{\"schemas\":[\"{s}\"],\"Operations\":[{{\"op\":{f}", .{ check.urn.patch_op, std.json.fmt(op, .{}) });
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

test {
    _ = Client;
    _ = check;
    _ = @import("json.zig");
}

test parseArgs {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var discard: Io.Writer.Discarding = .init(&.{});
    const args = try parseArgs(arena_state.allocator(), &.{ "-u", "http://x/scim/v2", "list", "Users", "--filter=userName eq \"a\"", "--count", "5", "-v" }, &discard.writer);
    try std.testing.expectEqualStrings("http://x/scim/v2", args.url.?);
    try std.testing.expectEqualStrings("userName eq \"a\"", args.filter.?);
    try std.testing.expectEqualStrings("5", args.count.?);
    try std.testing.expect(args.verbose);
    try std.testing.expectEqual(@as(usize, 2), args.positional.items.len);
    try std.testing.expectError(error.Usage, parseArgs(arena_state.allocator(), &.{"--bogus"}, &discard.writer));
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
        "{\"schemas\":[\"urn:ietf:params:scim:api:messages:2.0:SearchRequest\"],\"filter\":\"userName pr\",\"attributes\":[\"userName\",\"emails\"],\"count\":5}",
        try searchRequest(arena_state.allocator(), .{ .filter = "userName pr", .attributes = "userName,emails", .count = "5" }),
    );
}
