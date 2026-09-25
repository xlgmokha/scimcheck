//! Helpers for picking values out of SCIM documents.
//!
//! SCIM attribute names are case-insensitive (RFC 7643 §2.1), so every lookup
//! here ignores case.
const std = @import("std");
const Value = std.json.Value;

/// Returns the attribute `name` of an object, ignoring case.
pub fn field(v: ?Value, name: []const u8) ?Value {
    const obj = switch (v orelse return null) {
        .object => |o| o,
        else => return null,
    };
    if (obj.get(name)) |found| return found;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

/// Follows a dotted attribute path such as `meta.location` or `name.givenName`.
/// Extension attributes can be reached by passing the schema URN as a single
/// segment via `field`.
pub fn path(v: ?Value, dotted: []const u8) ?Value {
    var current = v;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |segment| current = field(current, segment);
    return current;
}

pub fn string(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn integer(v: ?Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f) @intFromFloat(f) else null,
        else => null,
    };
}

pub fn boolean(v: ?Value) ?bool {
    return switch (v orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn array(v: ?Value) ?[]const Value {
    return switch (v orelse return null) {
        .array => |a| a.items,
        else => null,
    };
}

pub fn isObject(v: ?Value) bool {
    return v != null and v.? == .object;
}

/// True when the `schemas` attribute lists `urn`.
pub fn hasSchema(v: ?Value, urn: []const u8) bool {
    for (array(field(v, "schemas")) orelse return false) |s| {
        if (string(s)) |str| if (std.ascii.eqlIgnoreCase(str, urn)) return true;
    }
    return false;
}

/// Finds the first element of a multi-valued attribute whose sub-attribute
/// `key` equals `expected`.
pub fn findBy(items: ?[]const Value, key: []const u8, expected: []const u8) ?Value {
    for (items orelse return null) |item| {
        if (string(field(item, key))) |s| if (std.mem.eql(u8, s, expected)) return item;
    }
    return null;
}

test field {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator,
        \\{"userName":"bjensen","meta":{"Location":"/Users/1"},"schemas":["urn:ietf:params:scim:schemas:core:2.0:User"],
        \\ "emails":[{"value":"a@example.com","type":"work"},{"value":"b@example.com","type":"home"}], "count": 2}
    , .{});
    defer parsed.deinit();
    const v = parsed.value;

    try std.testing.expectEqualStrings("bjensen", string(field(v, "USERNAME")).?);
    try std.testing.expectEqualStrings("/Users/1", string(path(v, "meta.location")).?);
    try std.testing.expect(path(v, "meta.missing.deeper") == null);
    try std.testing.expect(hasSchema(v, "urn:ietf:params:scim:schemas:core:2.0:user"));
    try std.testing.expect(!hasSchema(v, "urn:ietf:params:scim:schemas:core:2.0:Group"));
    try std.testing.expectEqual(@as(i64, 2), integer(field(v, "count")).?);
    const home = findBy(array(field(v, "emails")), "type", "home").?;
    try std.testing.expectEqualStrings("b@example.com", string(field(home, "value")).?);
}
