//! Querying with POST and a SearchRequest body (RFC 7644 §3.4.3), and
//! queries at the server root (RFC 7644 §3.4.2.1).
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;
const eql = check.eql;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.4.3";
    const f = s.requireFixtures() orelse return;
    const search = s.fmt("{s}/.search", .{s.users_endpoint});
    const anchor = s.fmt("userName sw \"{s}\"", .{s.fixturePrefix()});

    const first = s.send(.POST, search, .{ .body = request(s, s.fmt("\"filter\":{f}", .{std.json.fmt(s.fmt("userName eq \"{s}\"", .{f[1].user_name}), .{})})) }) orelse return;
    // RFC 7644 §3.4.3 makes POST queries optional ("Clients MAY"); once
    // supported, the SearchRequest rules below are MUSTs.
    if (!s.expectStatus(.may, ref, first, .ok, "POST /Users/.search is supported")) {
        s.skip("the remaining POST /.search checks");
    } else {
        if (s.expectList(ref, first, "POST /Users/.search returns a ListResponse")) |body| {
            _ = s.check(.must, ref, j.integer(j.field(body, "totalResults")) == 1, "  the filter is applied", first.body);
        }
        const projected = s.fmt("\"filter\":{f},\"attributes\":[\"userName\"]", .{std.json.fmt(anchor, .{})});
        if (s.send(.POST, search, .{ .body = request(s, projected) })) |res| {
            if (s.expectList(ref, res, "SearchRequest with attributes returns a ListResponse")) |body| {
                const r = check.firstResource(body);
                _ = s.check(.must, ref, r != null and j.field(r, "userName") != null and j.field(r, "emails") == null, "  attributes is applied", res.body);
            }
        }
        const excluded = s.fmt("\"filter\":{f},\"excludedAttributes\":[\"emails\"]", .{std.json.fmt(anchor, .{})});
        if (s.send(.POST, search, .{ .body = request(s, excluded) })) |res| {
            if (s.expectList(ref, res, "SearchRequest with excludedAttributes returns a ListResponse")) |body| {
                const r = check.firstResource(body);
                _ = s.check(.must, ref, r != null and j.field(r, "emails") == null and j.field(r, "userName") != null, "  excludedAttributes is applied", res.body);
            }
        }
        const paged = s.fmt("\"filter\":{f},\"startIndex\":2,\"count\":1", .{std.json.fmt(anchor, .{})});
        if (s.send(.POST, search, .{ .body = request(s, paged) })) |res| {
            if (s.expectList(ref, res, "SearchRequest with startIndex and count returns a ListResponse")) |body| {
                _ = s.check(.must, ref, check.resourceCount(body) == 1 and j.integer(j.field(body, "startIndex")) == 2 and j.integer(j.field(body, "totalResults")) == 3, "  paging is applied", res.body);
            }
        }
        if (s.caps.sort) {
            const sorted = s.fmt("\"filter\":{f},\"sortBy\":\"name.givenName\",\"sortOrder\":\"descending\"", .{std.json.fmt(anchor, .{})});
            if (s.send(.POST, search, .{ .body = request(s, sorted) })) |res| {
                if (s.expectList(ref, res, "SearchRequest with sortBy returns a ListResponse")) |body| {
                    _ = s.check(.must, ref, eql(j.string(j.field(check.firstResource(body), "id")), f[0].id), "  sorting is applied", res.body);
                }
            }
        }
        if (s.send(.POST, search, .{ .body = "{\"filter\":\"userName pr\"}" })) |res| {
            _ = s.expectStatus(.should, ref, res, .bad_request, "a SearchRequest without schemas returns 400");
        }
        if (s.send(.POST, search, .{ .body = request(s, "\"filter\":\"userName eq\"") })) |res| {
            s.expectError(.must, ref, res, .bad_request, "invalidFilter", "a SearchRequest with a malformed filter returns 400 invalidFilter");
        }
    }

    // Queries at the server root span every resource type. Support is optional.
    if (s.send(.POST, "/.search", .{ .body = request(s, s.fmt("\"filter\":{f}", .{std.json.fmt(anchor, .{})})) })) |res| {
        if (s.expectStatus(.may, "RFC7644 §3.4.3", res, .ok, "POST /.search at the root is supported")) {
            if (s.expectList(ref, res, "root POST /.search returns a ListResponse")) |body| {
                _ = s.check(.must, ref, j.integer(j.field(body, "totalResults")) == 3, "  root search finds the fixtures", res.body);
            }
        }
    }
    if (s.send(.GET, s.fmt("/?filter={s}", .{s.escape(anchor)}), .{})) |res| {
        if (s.expectStatus(.may, "RFC7644 §3.4.2.1", res, .ok, "GET /?filter= at the root is supported")) {
            _ = s.expectList("RFC7644 §3.4.2.1", res, "root query returns a ListResponse");
        }
    }
}

fn request(s: *Suite, members: []const u8) []const u8 {
    return s.fmt("{{\"schemas\":[\"{s}\"],{s}}}", .{ urn.search_request, members });
}
