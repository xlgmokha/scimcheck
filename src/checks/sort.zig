//! Sorting (RFC 7644 §3.4.2.3). The fixtures sort alice, bob, carol by
//! userName and by their first email, but bob, carol, alice by
//! name.givenName and by primary email, so each sortBy is distinguishable.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;
const eql = check.eql;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.4.2.3";
    if (!s.caps.sort) return s.skip("sort.supported is false");
    if (!s.caps.filter) return s.skip("filter.supported is false");
    const f = s.requireFixtures() orelse return;
    const base = s.fmt("{s}?filter={s}", .{ s.users_endpoint, s.escape(s.fmt("userName sw \"{s}\"", .{s.fixturePrefix()})) });

    const Case = struct { []const u8, [3]usize, []const u8, check.Level };
    const cases = [_]Case{
        .{ "sortBy=userName", .{ 0, 1, 2 }, "sortBy=userName defaults to ascending", .must },
        .{ "sortBy=userName&sortOrder=ascending", .{ 0, 1, 2 }, "sortOrder=ascending", .must },
        .{ "sortBy=userName&sortOrder=descending", .{ 2, 1, 0 }, "sortOrder=descending", .must },
        .{ "sortBy=name.givenName", .{ 1, 2, 0 }, "sortBy a sub-attribute (name.givenName)", .must },
        .{ "sortBy=name.givenName&sortOrder=descending", .{ 0, 2, 1 }, "sortBy a sub-attribute, descending", .must },
        .{ "sortBy=USERNAME", .{ 0, 1, 2 }, "sortBy attribute names are case-insensitive", .must },
        .{ s.fmt("sortBy={s}", .{s.escape(urn.user ++ ":userName")}), .{ 0, 1, 2 }, "sortBy a URN-qualified attribute", .must },
        .{ "sortBy=emails", .{ 1, 2, 0 }, "sortBy a multi-valued attribute uses the primary value", .must },
        .{ "sortBy=emails.value", .{ 1, 2, 0 }, "sortBy emails.value", .should },
        .{ "sortBy=meta.created", .{ 0, 1, 2 }, "sortBy meta.created orders by creation time", .should },
        .{ "sortBy=nickName", .{ 2, 0, 1 }, "resources without a value sort last when ascending", .should },
        .{ "sortBy=nickName&sortOrder=descending", .{ 1, 0, 2 }, "resources without a value sort first when descending", .should },
    };
    for (cases) |c| {
        const res = s.send(.GET, s.fmt("{s}&{s}", .{ base, c[0] }), .{}) orelse continue;
        if (res.status != .ok) {
            _ = s.check(c[3], ref, false, c[2], s.fmt("got HTTP {d}: {s}", .{ @intFromEnum(res.status), res.body }));
            continue;
        }
        const resources = j.array(j.field(s.json(res), "Resources")) orelse &.{};
        var ok = resources.len == 3;
        if (ok) for (c[1], 0..) |fixture, i| {
            ok = ok and eql(j.string(j.field(resources[i], "id")), f[fixture].id);
        };
        _ = s.check(c[3], ref, ok, c[2], s.fmt("order: {s}", .{order(s, resources, f)}));
    }

    if (s.send(.GET, s.fmt("{s}&sortOrder=descending", .{base}), .{})) |res| {
        _ = s.expectList(ref, res, "sortOrder without sortBy is accepted");
    }
    if (s.send(.GET, s.fmt("{s}&sortBy=userName&count=1&startIndex=2", .{base}), .{})) |res| {
        if (s.expectList(ref, res, "sorting combined with paging returns a ListResponse")) |body| {
            _ = s.check(.must, "RFC7644 §3.4.2.4", eql(j.string(j.field(check.firstResource(body), "id")), f[1].id), "  the page is taken from the sorted results", res.body);
        }
    }
}

/// Renders the order of resources as fixture names for failure messages.
fn order(s: *Suite, resources: []const std.json.Value, f: [3]check.Fixture) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (resources) |r| {
        const id = j.string(j.field(r, "id")) orelse "?";
        const name = for (f, [_][]const u8{ "alice", "bob", "carol" }) |fixture, n| {
            if (std.mem.eql(u8, fixture.id, id)) break n;
        } else id;
        if (out.items.len > 0) out.appendSlice(s.arena, ", ") catch {};
        out.appendSlice(s.arena, name) catch {};
    }
    return out.items;
}
