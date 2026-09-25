//! Resource versioning with ETags (RFC 7644 §3.14) and the conditional
//! request headers of RFC 7232. Runs against the bob fixture.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const eql = check.eql;

const stale = "W/\"scimcheck-stale\"";

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.14";
    if (!s.caps.etag) return s.skip("etag.supported is false");
    const f = s.requireFixtures() orelse return;
    const fixture = f[1];

    const res = s.send(.GET, fixture.path, .{}) orelse return;
    if (!s.expectStatus(.must, ref, res, .ok, "GET a resource returns 200")) return;
    const tag = res.etag orelse {
        _ = s.check(.must, ref, false, "GET returns an ETag header", null);
        return;
    };
    _ = s.check(.must, ref, true, "GET returns an ETag header", null);
    _ = s.check(.must, "RFC7232 §2.3", check.isEntityTag(tag), "the ETag is a quoted entity tag", tag);
    _ = s.check(.should, ref, eql(j.string(j.path(s.json(res), "meta.version")), tag), "meta.version equals the ETag header", null);
    if (s.send(.GET, fixture.path, .{})) |again| {
        _ = s.check(.must, ref, eql(again.etag, tag), "the ETag is stable while the resource is unchanged", again.etag);
    }

    if (s.send(.GET, fixture.path, .{ .if_none_match = tag })) |r| {
        if (s.expectStatus(.should, "RFC7232 §3.2", r, .not_modified, "If-None-Match with the current ETag returns 304")) {
            _ = s.check(.must, "RFC7232 §4.1", r.body.len == 0, "  a 304 response has no body", null);
        }
    }
    if (s.send(.GET, fixture.path, .{ .if_none_match = stale })) |r| {
        _ = s.expectStatus(.must, "RFC7232 §3.2", r, .ok, "If-None-Match with a stale ETag returns 200");
    }

    const body = s.userJson(.{ .user_name = fixture.user_name, .display_name = "Versioned" });
    if (s.send(.PUT, fixture.path, .{ .body = body, .if_match = stale })) |r| {
        s.expectError(.must, ref, r, .precondition_failed, null, "PUT with a stale If-Match returns 412");
    }
    if (s.caps.patch) {
        if (s.send(.PATCH, fixture.path, .{ .body = s.patchJson("{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"x\"}"), .if_match = stale })) |r| {
            s.expectError(.must, ref, r, .precondition_failed, null, "PATCH with a stale If-Match returns 412");
        }
    }
    if (s.send(.DELETE, fixture.path, .{ .if_match = stale })) |r| {
        s.expectError(.must, ref, r, .precondition_failed, null, "DELETE with a stale If-Match returns 412");
    }
    if (s.fetch(ref, fixture.path)) |v| {
        _ = s.check(.must, ref, !eql(j.string(j.field(v, "displayName")), "Versioned"), "a failed precondition leaves the resource unchanged", null);
    }

    var current = tag;
    if (s.send(.PUT, fixture.path, .{ .body = body, .if_match = current })) |r| {
        if (s.expectStatus(.must, ref, r, .ok, "PUT with the current If-Match returns 200")) {
            _ = s.check(.must, ref, r.etag != null, "  the PUT response includes an ETag", null);
            _ = s.check(.should, ref, r.etag != null and !eql(r.etag, tag), "  the ETag changes after an update", null);
            if (r.etag) |e| current = e;
        }
    }
    if (s.caps.patch) {
        if (s.send(.PATCH, fixture.path, .{ .body = s.patchJson("{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"Versioned Twice\"}"), .if_match = current })) |r| {
            if (s.expectStatusIn(.must, ref, r, &.{ .ok, .no_content }, "PATCH with the current If-Match succeeds")) {
                _ = s.check(.must, ref, r.etag != null, "  the PATCH response includes an ETag", null);
                _ = s.check(.should, ref, r.etag != null and !eql(r.etag, current), "  the ETag changes after PATCH", null);
            }
        }
    }
    if (s.send(.PUT, fixture.path, .{ .body = body, .if_match = "*" })) |r| {
        _ = s.expectStatus(.should, "RFC7232 §3.1", r, .ok, "If-Match: * matches any current version");
    }

    const temp = s.createUser(.{ .user_name = s.userName("etag-delete") }) orelse return;
    if (s.send(.GET, temp.path, .{})) |r| {
        if (s.send(.DELETE, temp.path, .{ .if_match = r.etag orelse stale })) |del| {
            if (s.expectStatus(.must, ref, del, .no_content, "DELETE with the current If-Match returns 204")) s.untrack(temp.path);
        }
    }
}
