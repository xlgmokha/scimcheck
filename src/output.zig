//! Renders SCIM documents as pretty JSON, JSON lines, bare ids, or a table.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const j = @import("json.zig");

pub const Format = enum {
    /// Pretty-printed JSON: the whole response, or an array when streaming.
    json,
    /// One compact JSON resource per line.
    jsonl,
    /// An aligned table of type, id and name.
    table,
    /// One id per line.
    ids,
};

pub const Printer = struct {
    arena: Allocator,
    out: *Io.Writer,
    format: Format,
    /// Add a TYPE column to tables, for listings that span resource types.
    show_type: bool = false,
    /// Set by `beginList`: resources are collected into one JSON array.
    listing: bool = false,
    rows: std.ArrayList([]const []const u8) = .empty,
    collected: std.ArrayList(Value) = .empty,
    count: usize = 0,

    /// Starts a stream of resources that `finish` closes, e.g. `list --all`.
    pub fn beginList(p: *Printer) void {
        p.listing = true;
    }

    /// Prints one resource. `type_name` fills the TYPE column.
    pub fn resource(p: *Printer, type_name: ?[]const u8, v: Value) !void {
        p.count += 1;
        switch (p.format) {
            .jsonl => {
                try std.json.Stringify.value(v, .{}, p.out);
                try p.out.writeByte('\n');
            },
            .ids => try p.out.print("{s}\n", .{j.string(j.field(v, "id")) orelse ""}),
            .json => if (p.listing) {
                try p.collected.append(p.arena, v);
            } else {
                try pretty(p.out, v);
            },
            .table => {
                const id = j.string(j.field(v, "id")) orelse "";
                const row: []const []const u8 = if (p.show_type)
                    try p.arena.dupe([]const u8, &.{ type_name orelse resourceType(v), id, displayName(v) })
                else
                    try p.arena.dupe([]const u8, &.{ id, displayName(v) });
                try p.rows.append(p.arena, row);
            },
        }
    }

    /// Prints a whole response body. In `json` format the body is printed as
    /// is; otherwise a ListResponse is unwrapped into its resources.
    pub fn document(p: *Printer, v: Value) !void {
        if (p.format == .json) return pretty(p.out, v);
        if (isListResponse(v)) {
            for (j.array(j.field(v, "Resources")) orelse &.{}) |r| try p.resource(null, r);
        } else {
            try p.resource(null, v);
        }
    }

    pub fn finish(p: *Printer) !void {
        switch (p.format) {
            .json => if (p.listing) try pretty(p.out, .{ .array = .{ .items = p.collected.items, .capacity = p.collected.items.len, .allocator = p.arena } }),
            .table => {
                const header: []const []const u8 = if (p.show_type) &.{ "TYPE", "ID", "NAME" } else &.{ "ID", "NAME" };
                try writeTable(p.arena, p.out, header, p.rows.items);
            },
            .jsonl, .ids => {},
        }
        try p.out.flush();
    }
};

pub fn pretty(out: *Io.Writer, v: Value) !void {
    try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

/// Writes rows as left-aligned columns separated by two spaces.
pub fn writeTable(arena: Allocator, out: *Io.Writer, header: []const []const u8, rows: []const []const []const u8) !void {
    const widths = try arena.alloc(usize, header.len);
    for (header, 0..) |h, i| widths[i] = h.len;
    for (rows) |row| for (row, 0..) |cell, i| {
        widths[i] = @max(widths[i], cell.len);
    };
    try writeRow(out, widths, header);
    for (rows) |row| try writeRow(out, widths, row);
}

fn writeRow(out: *Io.Writer, widths: []const usize, cells: []const []const u8) !void {
    for (cells, 0..) |cell, i| {
        try out.writeAll(cell);
        if (i + 1 < cells.len) try out.splatByteAll(' ', widths[i] - cell.len + 2);
    }
    try out.writeByte('\n');
}

pub fn isListResponse(v: Value) bool {
    return j.hasSchema(v, "urn:ietf:params:scim:api:messages:2.0:ListResponse");
}

/// A human-readable label for a resource: the first of userName,
/// displayName, name or externalId that is a string.
pub fn displayName(v: Value) []const u8 {
    inline for (.{ "userName", "displayName", "name", "externalId" }) |attr| {
        if (j.string(j.field(v, attr))) |s| return s;
    }
    return "";
}

fn resourceType(v: Value) []const u8 {
    return j.string(j.path(v, "meta.resourceType")) orelse "";
}

test writeTable {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try writeTable(arena_state.allocator(), &w, &.{ "ID", "NAME" }, &.{
        &.{ "1", "bjensen" },
        &.{ "2819c223", "jsmith" },
    });
    try std.testing.expectEqualStrings(
        \\ID        NAME
        \\1         bjensen
        \\2819c223  jsmith
        \\
    , w.buffered());
}

test Printer {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"schemas":["urn:ietf:params:scim:api:messages:2.0:ListResponse"],"totalResults":2,
        \\ "Resources":[{"id":"1","userName":"bjensen","meta":{"resourceType":"User"}},{"id":"g","displayName":"Admins"}]}
    , .{});

    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var ids: Printer = .{ .arena = arena, .out = &w, .format = .ids };
    try ids.document(list);
    try ids.finish();
    try std.testing.expectEqualStrings("1\ng\n", w.buffered());

    w = .fixed(&buf);
    var table: Printer = .{ .arena = arena, .out = &w, .format = .table, .show_type = true };
    try table.document(list);
    try table.finish();
    try std.testing.expectEqualStrings(
        \\TYPE  ID  NAME
        \\User  1   bjensen
        \\      g   Admins
        \\
    , w.buffered());

    w = .fixed(&buf);
    var lines: Printer = .{ .arena = arena, .out = &w, .format = .jsonl };
    try lines.document(list);
    try std.testing.expectEqualStrings(
        \\{"id":"1","userName":"bjensen","meta":{"resourceType":"User"}}
        \\{"id":"g","displayName":"Admins"}
        \\
    , w.buffered());

    w = .fixed(&buf);
    var array: Printer = .{ .arena = arena, .out = &w, .format = .json };
    array.beginList();
    try array.finish();
    try std.testing.expectEqualStrings("[]\n", w.buffered());
}
