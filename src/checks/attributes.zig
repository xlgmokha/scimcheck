//! The `attributes` and `excludedAttributes` parameters (RFC 7644 §3.9)
//! and attribute notation (RFC 7644 §3.10) on reads and writes.
const std = @import("std");
const Value = std.json.Value;

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.9";
    const f = s.requireFixtures() orelse return;
    const path = f[0].path;

    if (project(s, path, "attributes=userName", "attributes=userName")) |v| {
        _ = s.check(.must, ref, j.field(v, "userName") != null, "  userName is returned", null);
        _ = s.check(.must, "RFC7643 §7", j.field(v, "id") != null, "  id is still returned (returned: always)", null);
        _ = s.check(.must, ref, j.field(v, "displayName") == null and j.field(v, "emails") == null, "  other attributes are omitted", fmtValue(s, v));
    }
    if (project(s, path, s.fmt("attributes={s}", .{s.escape(urn.user ++ ":userName")}), "attributes with a fully qualified URN")) |v| {
        _ = s.check(.must, "RFC7644 §3.10", j.field(v, "userName") != null and j.field(v, "displayName") == null, "  URN-qualified names select core attributes", fmtValue(s, v));
    }
    if (project(s, path, "attributes=USERNAME", "attribute names in attributes= are case-insensitive")) |v| {
        _ = s.check(.must, "RFC7643 §2.1", j.field(v, "userName") != null and j.field(v, "emails") == null, "  USERNAME selects userName", fmtValue(s, v));
    }
    if (project(s, path, "attributes=name", "attributes=name (a complex attribute)")) |v| {
        _ = s.check(.must, ref, j.path(v, "name.givenName") != null and j.path(v, "name.familyName") != null, "  a complex attribute returns its sub-attributes", fmtValue(s, v));
    }
    if (project(s, path, "attributes=name.givenName", "attributes=name.givenName (a sub-attribute)")) |v| {
        _ = s.check(.must, ref, j.path(v, "name.givenName") != null and j.path(v, "name.familyName") == null, "  sibling sub-attributes are omitted", fmtValue(s, v));
    }
    if (project(s, path, "attributes=emails.value", "attributes=emails.value (a multi-valued sub-attribute)")) |v| {
        const emails = j.array(j.field(v, "emails")) orelse &.{};
        _ = s.check(.must, ref, emails.len > 0 and j.field(emails[0], "value") != null and j.field(emails[0], "type") == null, "  only value is returned for each email", fmtValue(s, v));
    }
    if (project(s, path, "attributes=userName,displayName", "attributes with a comma-separated list")) |v| {
        _ = s.check(.must, ref, j.field(v, "userName") != null and j.field(v, "displayName") != null and j.field(v, "emails") == null, "  both listed attributes are returned", fmtValue(s, v));
    }
    if (project(s, path, "attributes=password", "attributes=password")) |v| {
        _ = s.check(.must, "RFC7643 §7", j.field(v, "password") == null, "  returned: never attributes stay hidden when requested", fmtValue(s, v));
    }
    if (project(s, path, "excludedAttributes=emails", "excludedAttributes=emails")) |v| {
        _ = s.check(.must, ref, j.field(v, "emails") == null, "  emails is omitted", fmtValue(s, v));
        _ = s.check(.must, ref, j.field(v, "userName") != null and j.field(v, "displayName") != null, "  other attributes are kept", null);
    }
    if (project(s, path, "excludedAttributes=name.familyName", "excludedAttributes=name.familyName")) |v| {
        _ = s.check(.should, ref, j.path(v, "name.familyName") == null and j.path(v, "name.givenName") != null, "  only the excluded sub-attribute is omitted", fmtValue(s, v));
    }
    if (project(s, path, "excludedAttributes=id", "excludedAttributes=id")) |v| {
        _ = s.check(.must, "RFC7643 §7", j.field(v, "id") != null, "  id cannot be excluded (returned: always)", null);
    }

    if (s.caps.filter) {
        const filter = s.escape(s.fmt("userName eq \"{s}\"", .{f[0].user_name}));
        if (s.send(.GET, s.fmt("{s}?filter={s}&attributes=displayName", .{ s.users_endpoint, filter }), .{})) |res| {
            if (s.expectList(ref, res, "list with attributes=displayName returns a ListResponse")) |body| {
                const first = check.firstResource(body);
                _ = s.check(.must, ref, first != null and j.field(first, "displayName") != null and j.field(first, "emails") == null and j.field(first, "id") != null, "  attributes applies to each listed resource", res.body);
            }
        }
        if (s.send(.GET, s.fmt("{s}?filter={s}&excludedAttributes=emails", .{ s.users_endpoint, filter }), .{})) |res| {
            if (s.expectList(ref, res, "list with excludedAttributes=emails returns a ListResponse")) |body| {
                const first = check.firstResource(body);
                _ = s.check(.must, ref, first != null and j.field(first, "emails") == null and j.field(first, "userName") != null, "  excludedAttributes applies to each listed resource", res.body);
            }
        }
    }

    // RFC 7644 §3.9: the parameters also apply to POST, PUT and PATCH responses.
    const user_name = s.userName("projection");
    if (s.send(.POST, s.fmt("{s}?attributes=userName", .{s.users_endpoint}), .{ .body = s.userJson(.{ .user_name = user_name }) })) |res| {
        s.trackCreated(s.users_endpoint, res);
        if (s.expectStatus(.must, "RFC7644 §3.3", res, .created, "POST ?attributes=userName returns 201")) {
            const v = s.json(res);
            _ = s.check(.should, ref, j.field(v, "userName") != null and j.field(v, "displayName") == null, "  the POST response is projected", res.body);
            const id = j.string(j.field(v, "id")) orelse return;
            const created = s.fmt("{s}/{s}", .{ s.users_endpoint, id });
            if (s.send(.PUT, s.fmt("{s}?excludedAttributes=emails", .{created}), .{ .body = s.userJson(.{ .user_name = user_name }) })) |put| {
                if (s.expectStatus(.must, "RFC7644 §3.5.1", put, .ok, "PUT ?excludedAttributes=emails returns 200")) {
                    _ = s.check(.should, ref, j.field(s.json(put), "emails") == null, "  the PUT response is projected", put.body);
                }
            }
            if (s.caps.patch) {
                const op = s.patchJson("{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"Projected\"}");
                if (s.send(.PATCH, s.fmt("{s}?attributes=displayName", .{created}), .{ .body = op })) |patch| {
                    if (s.expectStatus(.should, "RFC7644 §3.5.2", patch, .ok, "PATCH ?attributes=displayName returns 200 with the resource")) {
                        const p = s.json(patch);
                        _ = s.check(.should, ref, j.field(p, "displayName") != null and j.field(p, "userName") == null, "  the PATCH response is projected", patch.body);
                    }
                }
            }
        }
    }

    if (s.send(.GET, s.fmt("{s}?attributes=scimcheckNoSuchAttribute", .{path}), .{})) |res| {
        _ = s.expectStatusIn(.may, ref, res, &.{ .ok, .bad_request }, "an unknown attribute in attributes= is ignored or rejected with 400");
    }
}

/// GETs `path?query` and returns the body, recording the status check.
fn project(s: *Suite, path: []const u8, query: []const u8, what: []const u8) ?Value {
    const res = s.send(.GET, s.fmt("{s}?{s}", .{ path, query }), .{}) orelse return null;
    if (!s.expectStatus(.must, "RFC7644 §3.9", res, .ok, s.fmt("GET with {s} returns 200", .{what}))) return null;
    return s.json(res);
}

fn fmtValue(s: *Suite, v: Value) []const u8 {
    return s.fmt("{f}", .{std.json.fmt(v, .{})});
}
