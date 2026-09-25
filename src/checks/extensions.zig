//! Schema extensions (RFC 7643 §3.3) using the enterprise User extension
//! (RFC 7643 §4.3): storage, retrieval, filtering, projection, sorting
//! and PATCH of extension attributes.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;
const eql = check.eql;

const ext = urn.enterprise_user;

pub fn run(s: *Suite) void {
    const ref = "RFC7643 §3.3";
    if (!s.enterprise_user) return s.skip("the User resource type does not list the enterprise extension");
    const f = s.requireFixtures() orelse return;

    const user_name = s.userName("enterprise");
    const number = s.fmt("{s}-e", .{s.run_id});
    const enterprise = s.fmt(
        \\{{"employeeNumber":{f},"department":"Research","costCenter":"4130","manager":{{"value":{f}}}}}
    , .{ std.json.fmt(number, .{}), std.json.fmt(f[0].id, .{}) });
    const res = s.send(.POST, s.users_endpoint, .{ .body = s.userJson(.{ .user_name = user_name, .enterprise = enterprise }) }) orelse return;
    if (!s.expectStatus(.must, "RFC7644 §3.3", res, .created, "POST a User with the enterprise extension returns 201")) return;
    const body = s.json(res);
    const id = j.string(j.field(body, "id")) orelse return;
    const path = s.fmt("{s}/{s}", .{ s.users_endpoint, id });
    s.created.append(s.arena, path) catch {};

    _ = s.check(.must, ref, j.hasSchema(body, ext), "schemas lists the extension URN", res.body);
    const stored = j.field(body, ext);
    _ = s.check(.must, ref, eql(j.string(j.field(stored, "employeeNumber")), number) and eql(j.string(j.field(stored, "department")), "Research"), "extension attributes are stored under the extension URN", res.body);
    _ = s.check(.should, "RFC7643 §4.3", eql(j.string(j.path(stored, "manager.value")), f[0].id), "manager.value references the manager's id", res.body);

    if (s.fetch("RFC7644 §3.4.1", path)) |got| {
        _ = s.check(.must, ref, eql(j.string(j.path(j.field(got, ext), "costCenter")), "4130"), "GET returns extension attributes", null);
    }

    if (s.caps.filter) {
        s.expectCount("RFC7644 §3.10", .must, s.fmt("{s}:employeeNumber eq \"{s}\"", .{ ext, number }), 1, "filter on a URN-qualified extension attribute");
        s.expectCount("RFC7644 §3.10", .must, s.fmt("userName sw \"{s}\" and {s}:department eq \"Eng\"", .{ s.fixturePrefix(), ext }), 2, "extension filter combined with a core attribute");
        s.expectCount("RFC7644 §3.10", .should, s.fmt("{s}:manager.value eq \"{s}\"", .{ ext, f[0].id }), 1, "filter on an extension sub-attribute");
    }

    if (s.send(.GET, s.fmt("{s}?attributes={s}", .{ path, s.escape(s.fmt("{s}:employeeNumber", .{ext})) }), .{})) |r| {
        if (s.expectStatus(.must, "RFC7644 §3.9", r, .ok, "attributes= accepts an extension attribute")) {
            const v = s.json(r);
            _ = s.check(.must, "RFC7644 §3.9", j.field(j.field(v, ext), "employeeNumber") != null and j.field(j.field(v, ext), "department") == null and j.field(v, "displayName") == null, "  only the requested extension attribute is returned", r.body);
        }
    }
    if (s.send(.GET, s.fmt("{s}?excludedAttributes={s}", .{ path, s.escape(ext) }), .{})) |r| {
        if (s.expectStatus(.must, "RFC7644 §3.9", r, .ok, "excludedAttributes= accepts an extension URN")) {
            _ = s.check(.should, "RFC7644 §3.9", j.field(s.json(r), ext) == null, "  the whole extension is omitted", r.body);
        }
    }

    if (s.caps.sort and s.caps.filter) {
        const target = s.fmt("{s}?filter={s}&sortBy={s}&sortOrder=descending", .{ s.users_endpoint, s.escape(s.fmt("userName sw \"{s}\"", .{s.fixturePrefix()})), s.escape(s.fmt("{s}:employeeNumber", .{ext})) });
        if (s.send(.GET, target, .{})) |r| {
            if (s.expectList("RFC7644 §3.4.2.3", r, "sortBy an extension attribute returns a ListResponse")) |list| {
                const resources = j.array(j.field(list, "Resources")) orelse &.{};
                const ok = resources.len == 3 and eql(j.string(j.field(resources[0], "id")), f[2].id) and eql(j.string(j.field(resources[2], "id")), f[0].id);
                _ = s.check(.should, "RFC7644 §3.4.2.3", ok, "  resources are ordered by employeeNumber", r.body);
            }
        }
    }

    if (s.caps.patch) {
        s.expectPatch("RFC7644 §3.10", path, s.fmt("{{\"op\":\"replace\",\"path\":\"{s}:department\",\"value\":\"Platform\"}}", .{ext}), "PATCH replace a URN-qualified extension path", s.fmt("{s}:department", .{ext}), "Platform");
        s.expectPatch("RFC7644 §3.5.2.3", path, s.fmt("{{\"op\":\"replace\",\"value\":{{\"{s}\":{{\"costCenter\":\"9000\"}}}}}}", .{ext}), "PATCH replace an extension object without a path", s.fmt("{s}:costCenter", .{ext}), "9000");
        if (s.fetch("RFC7644 §3.5.2.3", path)) |v| {
            _ = s.check(.must, "RFC7644 §3.5.2.3", eql(j.string(j.field(j.field(v, ext), "department")), "Platform"), "  sub-attributes not in the value are left unchanged", null);
        }
        s.expectPatch("RFC7644 §3.5.2.2", path, s.fmt("{{\"op\":\"remove\",\"path\":\"{s}:costCenter\"}}", .{ext}), "PATCH remove an extension attribute", null, null);
        if (s.fetch("RFC7644 §3.5.2.2", path)) |v| {
            _ = s.check(.must, "RFC7644 §3.5.2.2", j.field(j.field(v, ext), "costCenter") == null, "  costCenter is gone", null);
        }
    }

    // A PUT without the extension removes it.
    if (s.send(.PUT, path, .{ .body = s.userJson(.{ .user_name = user_name }) })) |r| {
        if (s.expectStatus(.must, "RFC7644 §3.5.1", r, .ok, "PUT without the extension returns 200")) {
            const v = s.json(r);
            _ = s.check(.must, "RFC7644 §3.5.1", j.field(v, ext) == null, "  the extension attributes are removed", r.body);
            _ = s.check(.should, ref, !j.hasSchema(v, ext), "  the extension URN is dropped from schemas", r.body);
        }
    }
}
