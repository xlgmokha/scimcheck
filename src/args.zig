//! Command line flags and help text.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const version = "0.3.0";

pub const usage =
    \\scimcheck - test and manage SCIM 2.0 service providers (RFC 7643, RFC 7644)
    \\
    \\Usage:
    \\  scimcheck [options] check [--only SECTIONS] [--keep]
    \\  scimcheck [options] types
    \\  scimcheck [options] list [TYPE] [--all] [query flags]
    \\  scimcheck [options] search [TYPE] [--all] [query flags]
    \\  scimcheck [options] get TYPE ID | get PATH [--attributes A] [--excluded-attributes A]
    \\  scimcheck [options] create TYPE [--data JSON | --file PATH]
    \\  scimcheck [options] replace TYPE ID [--data JSON | --file PATH] [--if-match ETAG]
    \\  scimcheck [options] patch TYPE ID [--data JSON | --file PATH | --op OP [--path P] [--value JSON]]
    \\  scimcheck [options] delete TYPE ID [--if-match ETAG]
    \\
    \\TYPE is a resource type name from 'scimcheck types' (User, Group, ...) or
    \\its endpoint (Users, /Groups). Any other path, e.g. Users/2819c223 or
    \\ServiceProviderConfig, is sent as is.
    \\
    \\Commands:
    \\  check    Run the RFC 7643/7644 conformance suite
    \\  types    List the resource types the server supports (/ResourceTypes)
    \\  list     List resources of TYPE, or every resource of every type when
    \\           TYPE is omitted (implies --all)
    \\  search   Like list, using POST /.search; without TYPE searches all types
    \\  get      Fetch one resource, or any path such as Schemas
    \\  create   POST a new resource read from --data, --file, or stdin
    \\  replace  PUT a full resource
    \\  patch    PATCH a resource with a PatchOp
    \\  delete   DELETE a resource
    \\
    \\Options:
    \\  -u, --url URL        Base URL of the service provider (env SCIM_URL)
    \\  -t, --token TOKEN    Bearer token (env SCIM_TOKEN)
    \\  -o, --output FORMAT  json, jsonl, table or ids. Defaults to json for a
    \\                       single response, jsonl for --all, table for types
    \\  -v, --verbose        Print every HTTP request and response to stderr
    \\  -h, --help           Show this help
    \\      --version        Show the version
    \\
    \\Query flags (list, search):
    \\  --filter F  --sort-by A  --sort-order ascending|descending
    \\  --start-index N  --count N (page size with --all)
    \\  --attributes A,B  --excluded-attributes A,B
    \\  --all       Follow pages until every result has been read
    \\
    \\Check sections (for --only, comma separated):
    \\  auth, errors, users, extensions, attributes, filter, search, pagination,
    \\  sort, patch, etag, groups, bulk
    \\
    \\Examples:
    \\  scimcheck -u http://localhost:8080/scim/v2 -t secret check
    \\  scimcheck types
    \\  scimcheck list -o table                       # everything on the server
    \\  scimcheck list User --filter 'userName sw "b"' --all -o ids
    \\  scimcheck create User --file bjensen.json
    \\  scimcheck get User 2819c223 --attributes userName,emails
    \\  scimcheck patch User 2819c223 --op replace --path active --value false
    \\  scimcheck delete Group e9e30dba
    \\
;

pub const Args = struct {
    url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    output: ?[]const u8 = null,
    verbose: bool = false,
    positional: std.ArrayList([]const u8) = .empty,
    only: ?[]const u8 = null,
    keep: bool = false,
    all: bool = false,
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
    .{ "--output", "output", "-o" },
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

/// Boolean flags: name, Args field.
const bool_flags = [_]struct { []const u8, []const u8 }{
    .{ "-v", "verbose" },
    .{ "--verbose", "verbose" },
    .{ "--keep", "keep" },
    .{ "--all", "all" },
};

pub fn parse(arena: Allocator, argv: []const []const u8, stderr: *Io.Writer) !Args {
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
        inline for (bool_flags) |flag| {
            if (std.mem.eql(u8, arg, flag[0])) {
                @field(args, flag[1]) = true;
                continue :next;
            }
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

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var discard: Io.Writer.Discarding = .init(&.{});
    const args = try parse(arena_state.allocator(), &.{ "-u", "http://x/scim/v2", "list", "User", "--filter=userName eq \"a\"", "--count", "5", "-v", "--all", "-o", "ids" }, &discard.writer);
    try std.testing.expectEqualStrings("http://x/scim/v2", args.url.?);
    try std.testing.expectEqualStrings("userName eq \"a\"", args.filter.?);
    try std.testing.expectEqualStrings("5", args.count.?);
    try std.testing.expectEqualStrings("ids", args.output.?);
    try std.testing.expect(args.verbose and args.all);
    try std.testing.expectEqual(@as(usize, 2), args.positional.items.len);
    try std.testing.expectError(error.Usage, parse(arena_state.allocator(), &.{"--bogus"}, &discard.writer));
}
