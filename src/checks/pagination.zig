//! Index-based pagination (RFC 7644 §3.4.2.4) over the three fixtures.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.4.2.4";
    if (!s.caps.filter) return s.skip("filter.supported is false");
    _ = s.requireFixtures() orelse return;
    const base = s.fmt("{s}?filter={s}", .{ s.users_endpoint, s.escape(s.fmt("userName sw \"{s}\"", .{s.fixturePrefix()})) });

    if (page(s, base, "", "no paging parameters")) |body| {
        _ = s.check(.must, ref, check.resourceCount(body) == 3, "  every result is returned", null);
        var identified = true;
        for (j.array(j.field(body, "Resources")) orelse &.{}) |r| {
            const id = j.string(j.field(r, "id")) orelse "";
            identified = identified and id.len > 0 and j.hasSchema(r, check.urn.user);
        }
        _ = s.check(.must, "RFC7643 §3", identified, "  each listed resource has an id and lists the User schema", null);
        _ = s.check(.must, ref, j.integer(j.field(body, "startIndex")) == 1, "  startIndex defaults to 1", null);
    }
    if (page(s, base, "&count=1", "count=1")) |body| {
        _ = s.check(.must, ref, j.integer(j.field(body, "totalResults")) == 3, "  totalResults counts every match, not the page", null);
        _ = s.check(.must, ref, check.resourceCount(body) == 1, "  one resource is returned", null);
        _ = s.check(.must, ref, j.integer(j.field(body, "itemsPerPage")) == 1, "  itemsPerPage is 1", null);
    }
    if (page(s, base, "&startIndex=3&count=2", "startIndex=3&count=2")) |body| {
        _ = s.check(.must, ref, j.integer(j.field(body, "startIndex")) == 3, "  startIndex is echoed", null);
        _ = s.check(.must, ref, check.resourceCount(body) == 1, "  the last page holds the remaining resource", null);
    }
    if (page(s, base, "&startIndex=10", "startIndex beyond totalResults")) |body| {
        _ = s.check(.must, ref, check.resourceCount(body) == 0, "  no resources are returned", null);
        _ = s.check(.must, ref, j.integer(j.field(body, "totalResults")) == 3, "  totalResults is still reported", null);
    }
    if (page(s, base, "&count=0", "count=0")) |body| {
        _ = s.check(.must, ref, check.resourceCount(body) == 0, "  no resources are returned", null);
        _ = s.check(.must, ref, j.integer(j.field(body, "totalResults")) == 3, "  totalResults is still reported", null);
    }
    if (page(s, base, "&startIndex=0", "startIndex=0")) |body| {
        _ = s.check(.must, ref, j.integer(j.field(body, "startIndex")) == 1, "  startIndex < 1 is interpreted as 1", null);
    }
    if (page(s, base, "&count=-1", "count=-1")) |body| {
        _ = s.check(.must, ref, check.resourceCount(body) == 0, "  a negative count is interpreted as 0", null);
    }
    if (s.caps.max_results) |max| maxResults(s, max);

    // Walking the pages one at a time visits every fixture exactly once.
    const sort = if (s.caps.sort) "&sortBy=userName" else "";
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var start: usize = 1;
    while (start <= 3) : (start += 1) {
        const res = s.send(.GET, s.fmt("{s}{s}&startIndex={d}&count=1", .{ base, sort, start }), .{}) orelse return;
        const body = s.json(res);
        if (check.firstResource(body)) |r| if (j.string(j.field(r, "id"))) |id| {
            seen.put(s.arena, id, {}) catch {};
        };
    }
    // Without sortBy the RFC does not promise a stable order between requests.
    const level: check.Level = if (s.caps.sort) .must else .should;
    _ = s.check(level, ref, seen.count() == 3, "paging with count=1 visits every result exactly once", null);
}

/// Creating more Users than this to exceed filter.maxResults is too costly;
/// the check is skipped instead.
const max_fillers = 100;

/// RFC 7643 §5: a page never holds more than filter.maxResults resources.
/// The limit can only be exceeded with more Users than it, so throwaway
/// Users are created when the server has too few.
fn maxResults(s: *Suite, max: i64) void {
    if (max < 1) return;
    const target = s.fmt("{s}?attributes=id&count={d}", .{ s.users_endpoint, max + 1 });
    var body = pageOrTooMany(s, target, "count above filter.maxResults") orelse return;
    const total = j.integer(j.field(body, "totalResults")) orelse return;
    var fillers: std.ArrayList([]const u8) = .empty;
    defer for (fillers.items) |path| {
        if (s.client.send(s.arena, .DELETE, path, .{})) |res| {
            if (res.status == .no_content) s.untrack(path);
        } else |_| {}
    };
    if (total <= max) {
        const missing = max + 1 - total;
        if (missing > max_fillers) return s.skip("fewer than filter.maxResults + 1 Users, so the limit cannot be exceeded");
        var i: i64 = 0;
        while (i < missing) : (i += 1) {
            const filler = s.createUser(.{ .user_name = s.userName(s.fmt("page-{d}", .{i})) }) orelse return;
            fillers.append(s.arena, filler.path) catch {};
        }
        body = pageOrTooMany(s, target, "count above filter.maxResults with more Users than the limit") orelse return;
    }
    const per_page = j.integer(j.field(body, "itemsPerPage")) orelse @as(i64, @intCast(check.resourceCount(body)));
    _ = s.check(.must, "RFC7643 §5", per_page <= max and check.resourceCount(body) <= max, "  no more than maxResults are returned", s.fmt("maxResults is {d}, got {d} resources", .{ max, check.resourceCount(body) }));
}

fn page(s: *Suite, base: []const u8, query: []const u8, what: []const u8) ?std.json.Value {
    const res = s.send(.GET, s.fmt("{s}{s}", .{ base, query }), .{}) orelse return null;
    return s.expectList("RFC7644 §3.4.2.4", res, s.fmt("{s} returns a ListResponse", .{what}));
}

/// RFC 7644 §3.4.2.1: when too many results would be returned, a service
/// provider SHALL either reject the request with 400 `tooMany`, or (as
/// `page` checks elsewhere) cap the page at `filter.maxResults`. Returns the
/// ListResponse body when the server capped the page, or null when it
/// rejected the request (already checked) or on any other failure.
fn pageOrTooMany(s: *Suite, target: []const u8, what: []const u8) ?std.json.Value {
    const res = s.send(.GET, target, .{}) orelse return null;
    if (res.status == .bad_request) {
        s.expectError(.must, "RFC7644 §3.4.2.1", res, .bad_request, "tooMany", s.fmt("{s} returns 400 tooMany or a capped ListResponse", .{what}));
        return null;
    }
    return s.expectList("RFC7644 §3.4.2.4", res, s.fmt("{s} returns a ListResponse", .{what}));
}
