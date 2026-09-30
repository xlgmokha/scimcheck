//! Bulk operations (RFC 7644 §3.7): bulkId references, required fields,
//! continuing after a failure, failOnErrors, maxOperations and
//! maxPayloadSize, or 501 when bulk is unsupported.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;
const eql = check.eql;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.7";
    if (!s.caps.bulk) {
        const res = s.send(.POST, "/Bulk", .{ .body = s.fmt("{{\"schemas\":[\"{s}\"],\"Operations\":[]}}", .{urn.bulk_request}) }) orelse return;
        s.expectError(.should, "RFC7644 §3.12", res, .not_implemented, null, "POST /Bulk returns 501 when bulk is unsupported");
        return;
    }

    // Create a user and a group that references it through its bulkId.
    const user_name = s.userName("bulk");
    const group_name = s.fmt("scimcheck-{s}-bulk-group", .{s.run_id});
    const group = s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":{f},\"members\":[{{\"value\":\"bulkId:u1\"}}]}}", .{ urn.group, std.json.fmt(group_name, .{}) });
    const payload = s.fmt(
        \\{{"schemas":["{s}"],"Operations":[{{"method":"POST","path":{f},"bulkId":"u1","data":{s}}},{{"method":"POST","path":{f},"bulkId":"g1","data":{s}}}]}}
    , .{ urn.bulk_request, std.json.fmt(s.users_endpoint, .{}), s.userJson(.{ .user_name = user_name }), std.json.fmt(s.groups_endpoint orelse "/Groups", .{}), group });
    const res = s.send(.POST, "/Bulk", .{ .body = payload }) orelse return;
    if (!s.expectStatus(.must, ref, res, .ok, "POST /Bulk returns 200")) return;
    const body = s.json(res);
    _ = s.check(.must, ref, j.hasSchema(body, urn.bulk_response), "the response lists the BulkResponse schema", null);
    const ops = j.array(j.field(body, "Operations")) orelse &.{};
    const user_op = j.findBy(ops, "bulkId", "u1");
    const group_op = j.findBy(ops, "bulkId", "g1");
    _ = s.check(.must, ref, eql(j.string(j.field(user_op, "status")), "201") and eql(j.string(j.field(group_op, "status")), "201"), "each create reports status \"201\" with its bulkId", res.body);
    const user_location = j.string(j.field(user_op, "location"));
    _ = s.check(.must, ref, user_location != null and j.string(j.field(group_op, "location")) != null, "each create returns a location", null);
    if (j.string(j.field(group_op, "location"))) |loc| s.created.append(s.arena, loc) catch {};
    if (user_location) |loc| s.created.append(s.arena, loc) catch {};
    if (j.string(j.field(group_op, "location"))) |loc| {
        if (s.fetch(ref, loc)) |g| {
            const group_members = j.array(j.field(g, "members")) orelse &.{};
            const member_id = if (group_members.len > 0) j.string(j.field(group_members[0], "value")) orelse "" else "";
            _ = s.check(.must, ref, user_location != null and std.mem.endsWith(u8, user_location.?, member_id) and member_id.len > 0, "bulkId:u1 is resolved to the new User's id", member_id);
        }
    }

    if (user_location) |loc| modify(s, loc);
    if (s.groups_endpoint) |endpoint| circular(s, endpoint);
    missingBulkId(s);
    continuesAfterFailure(s);

    // failOnErrors=1 stops processing after the first error.
    const failing = s.fmt(
        \\{{"schemas":["{s}"],"failOnErrors":1,"Operations":[{{"method":"POST","path":{f},"bulkId":"bad","data":{{"schemas":["{s}"]}}}},{{"method":"POST","path":{f},"bulkId":"never","data":{s}}}]}}
    , .{ urn.bulk_request, std.json.fmt(s.users_endpoint, .{}), urn.user, std.json.fmt(s.users_endpoint, .{}), s.userJson(.{ .user_name = s.userName("bulk-never") }) });
    if (s.send(.POST, "/Bulk", .{ .body = failing })) |r| {
        if (s.expectStatus(.must, ref, r, .ok, "POST /Bulk with failOnErrors returns 200")) {
            const results = j.array(j.field(s.json(r), "Operations")) orelse &.{};
            const never = j.findBy(results, "bulkId", "never");
            if (j.string(j.field(never, "location"))) |loc| s.created.append(s.arena, loc) catch {};
            _ = s.check(.must, ref, never == null, "  operations after failOnErrors is reached are not processed", r.body);
            const bad = j.findBy(results, "bulkId", "bad");
            _ = s.check(.must, ref, j.string(j.field(bad, "status")) != null and !eql(j.string(j.field(bad, "status")), "201"), "  the failed operation reports its error status", r.body);
            // RFC 7644 §3.7.3: a non-2xx result MUST include the response body.
            _ = s.check(.must, "RFC7644 §3.7.3", j.hasSchema(j.field(bad, "response"), urn.@"error"), "  the failed operation includes its error response", r.body);
        }
    }

    // RFC 7644 §3.7.4: a request over maxPayloadSize is rejected with 413.
    if (s.caps.bulk_max_payload_size) |max| {
        if (max > 0 and max <= 8 << 20) {
            const padding = s.arena.alloc(u8, @intCast(max)) catch return;
            @memset(padding, 'x');
            const data = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f},\"displayName\":\"{s}\"}}", .{ urn.user, std.json.fmt(s.userName("bulk-huge"), .{}), padding });
            const huge = s.fmt("{{\"schemas\":[\"{s}\"],\"Operations\":[{{\"method\":\"POST\",\"path\":{f},\"bulkId\":\"huge\",\"data\":{s}}}]}}", .{ urn.bulk_request, std.json.fmt(s.users_endpoint, .{}), data });
            if (s.send(.POST, "/Bulk", .{ .body = huge })) |r| {
                s.expectError(.must, "RFC7644 §3.7.4", r, .payload_too_large, null, "a request larger than maxPayloadSize returns 413");
                if (r.status == .ok) {
                    const results = j.array(j.field(s.json(r), "Operations")) orelse &.{};
                    if (j.string(j.field(j.findBy(results, "bulkId", "huge"), "location"))) |loc| s.created.append(s.arena, loc) catch {};
                }
            }
        }
    }

    // More operations than maxOperations is rejected with 413.
    if (s.caps.bulk_max_operations) |max| {
        if (max > 0 and max < 1000) {
            var ops_list: std.ArrayList(u8) = .empty;
            var i: i64 = 0;
            while (i <= max) : (i += 1) {
                if (i > 0) ops_list.append(s.arena, ',') catch {};
                ops_list.print(s.arena, "{{\"method\":\"DELETE\",\"path\":\"{s}/scimcheck-missing-{d}\"}}", .{ s.users_endpoint, i }) catch {};
            }
            const too_many = s.fmt("{{\"schemas\":[\"{s}\"],\"Operations\":[{s}]}}", .{ urn.bulk_request, ops_list.items });
            if (s.send(.POST, "/Bulk", .{ .body = too_many })) |r| {
                s.expectError(.must, ref, r, .payload_too_large, null, "more than maxOperations returns 413");
            }
        }
    }
}

/// PUT, PATCH and DELETE of the User created in bulk, in one request. Each
/// result reports its method, location and status (RFC 7644 §3.7.3).
fn modify(s: *Suite, location: []const u8) void {
    const ref = "RFC7644 §3.7";
    const id = location[(std.mem.findScalarLast(u8, location, '/') orelse return) + 1 ..];
    const path = s.fmt("{s}/{s}", .{ s.users_endpoint, id });
    const payload = s.fmt(
        \\{{"schemas":["{s}"],"Operations":[{{"method":"PUT","path":{f},"data":{s}}},{{"method":"PATCH","path":{f},"data":{s}}},{{"method":"DELETE","path":{f}}}]}}
    , .{
        urn.bulk_request,
        std.json.fmt(path, .{}),
        s.userJson(.{ .user_name = s.userName("bulk"), .display_name = "Bulk Replaced" }),
        std.json.fmt(path, .{}),
        s.patchJson("{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"Bulk Patched\"}"),
        std.json.fmt(path, .{}),
    });
    const res = s.send(.POST, "/Bulk", .{ .body = payload }) orelse return;
    if (!s.expectStatus(.must, ref, res, .ok, "POST /Bulk with PUT, PATCH and DELETE returns 200")) return;
    const results = j.array(j.field(s.json(res), "Operations")) orelse &.{};
    const Want = struct { []const u8, []const []const u8 };
    const wants = [_]Want{ .{ "PUT", &.{"200"} }, .{ "PATCH", &.{ "200", "204" } }, .{ "DELETE", &.{"204"} } };
    for (wants, 0..) |want, i| {
        const method, const statuses = want;
        const result = if (i < results.len) results[i] else null;
        const status = j.string(j.field(result, "status")) orelse "";
        var ok = false;
        for (statuses) |st| ok = ok or std.mem.eql(u8, st, status);
        _ = s.check(.must, "RFC7644 §3.7.3", ok and std.ascii.eqlIgnoreCase(j.string(j.field(result, "method")) orelse "", method) and j.string(j.field(result, "location")) != null, s.fmt("  {s} reports its method, location and a {s} status", .{ method, statuses[0] }), res.body);
    }
    if (s.send(.GET, path, .{})) |gone| {
        _ = s.expectStatus(.must, ref, gone, .not_found, "  the User deleted in bulk is gone");
    }
}

/// RFC 7644 §3.7: bulkId is REQUIRED when "method" is "POST". Accept either
/// the whole request rejected, or the operation reporting its own error.
fn missingBulkId(s: *Suite) void {
    const ref = "RFC7644 §3.7";
    const payload = s.fmt(
        \\{{"schemas":["{s}"],"Operations":[{{"method":"POST","path":{f},"data":{s}}}]}}
    , .{ urn.bulk_request, std.json.fmt(s.users_endpoint, .{}), s.userJson(.{ .user_name = s.userName("bulk-nobulkid") }) });
    const res = s.send(.POST, "/Bulk", .{ .body = payload }) orelse return;
    if (!s.expectStatusIn(.must, ref, res, &.{ .ok, .bad_request }, "  a POST operation missing bulkId is rejected, whole request or per-operation")) return;
    if (res.status == .bad_request) return;
    const results = j.array(j.field(s.json(res), "Operations")) orelse &.{};
    const op = if (results.len > 0) results[0] else null;
    if (j.string(j.field(op, "location"))) |loc| s.created.append(s.arena, loc) catch {};
    _ = s.check(.must, ref, !eql(j.string(j.field(op, "status")), "201"), "  the operation missing bulkId reports an error rather than succeeding", res.body);
}

/// RFC 7644 §3.7: "The service provider MUST continue performing as many
/// changes as possible and disregard partial failures" when failOnErrors is
/// not set.
fn continuesAfterFailure(s: *Suite) void {
    const ref = "RFC7644 §3.7";
    const payload = s.fmt(
        \\{{"schemas":["{s}"],"Operations":[{{"method":"POST","path":{f},"bulkId":"bad2","data":{{"schemas":["{s}"]}}}},{{"method":"POST","path":{f},"bulkId":"after","data":{s}}}]}}
    , .{ urn.bulk_request, std.json.fmt(s.users_endpoint, .{}), urn.user, std.json.fmt(s.users_endpoint, .{}), s.userJson(.{ .user_name = s.userName("bulk-after") }) });
    const res = s.send(.POST, "/Bulk", .{ .body = payload }) orelse return;
    if (!s.expectStatus(.must, ref, res, .ok, "POST /Bulk without failOnErrors returns 200")) return;
    const results = j.array(j.field(s.json(res), "Operations")) orelse &.{};
    const after = j.findBy(results, "bulkId", "after");
    if (j.string(j.field(after, "location"))) |loc| s.created.append(s.arena, loc) catch {};
    _ = s.check(.must, ref, eql(j.string(j.field(after, "status")), "201"), "  an operation after a failing one still succeeds without failOnErrors", res.body);
}

/// RFC 7644 §3.7.1: circular bulkId references MUST be resolved, or the
/// service provider MAY give up and report 409 for them.
fn circular(s: *Suite, endpoint: []const u8) void {
    const ref = "RFC7644 §3.7.1";
    const group = struct {
        fn json(suite: *Suite, name: []const u8, member: []const u8) []const u8 {
            return suite.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":{f},\"members\":[{{\"value\":\"bulkId:{s}\",\"type\":\"Group\"}}]}}", .{ urn.group, std.json.fmt(suite.fmt("scimcheck-{s}-bulk-{s}", .{ suite.run_id, name }), .{}), member });
        }
    }.json;
    const payload = s.fmt(
        \\{{"schemas":["{s}"],"Operations":[{{"method":"POST","path":{f},"bulkId":"ga","data":{s}}},{{"method":"POST","path":{f},"bulkId":"gb","data":{s}}}]}}
    , .{ urn.bulk_request, std.json.fmt(endpoint, .{}), group(s, "a", "gb"), std.json.fmt(endpoint, .{}), group(s, "b", "ga") });
    const res = s.send(.POST, "/Bulk", .{ .body = payload }) orelse return;
    if (!s.expectStatus(.must, ref, res, .ok, "POST /Bulk with circular bulkId references returns 200")) return;
    const results = j.array(j.field(s.json(res), "Operations")) orelse &.{};
    const a = j.findBy(results, "bulkId", "ga");
    const b = j.findBy(results, "bulkId", "gb");
    const conflict = eql(j.string(j.field(a, "status")), "409") or eql(j.string(j.field(b, "status")), "409");
    var resolved = true;
    for ([_]struct { ?std.json.Value, ?std.json.Value }{ .{ a, b }, .{ b, a } }) |pair| {
        const result, const other = pair;
        if (!eql(j.string(j.field(result, "status")), "201")) {
            resolved = false;
            continue;
        }
        const location = j.string(j.field(result, "location")) orelse "";
        if (location.len > 0) s.created.append(s.arena, location) catch {};
        const got = s.fetch(ref, location) orelse {
            resolved = false;
            continue;
        };
        const members = j.array(j.field(got, "members")) orelse &.{};
        const value = if (members.len > 0) j.string(j.field(members[0], "value")) orelse "" else "";
        const other_location = j.string(j.field(other, "location")) orelse "";
        resolved = resolved and value.len > 0 and std.mem.endsWith(u8, other_location, value);
    }
    _ = s.check(.must, ref, resolved or conflict, "  each Group references the other's new id, or the conflict is reported as 409", res.body);
}
