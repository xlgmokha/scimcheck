//! The Group resource (RFC 7643 §4.2): membership, member sub-attributes,
//! queries over members, PATCH and PUT of members, and User.groups.
const std = @import("std");
const Value = std.json.Value;

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;
const eql = check.eql;

pub fn run(s: *Suite) void {
    const ref = "RFC7643 §4.2";
    const endpoint = s.groups_endpoint orelse return s.skip("no Group resource type");
    const f = s.requireFixtures() orelse return;
    const display = s.fmt("scimcheck-{s}-group", .{s.run_id});

    const no_name = s.fmt("{{\"schemas\":[\"{s}\"],\"members\":[]}}", .{urn.group});
    if (s.send(.POST, endpoint, .{ .body = no_name })) |res| {
        s.expectError(.must, ref, res, .bad_request, "invalidValue", "POST a Group without the required displayName returns 400 invalidValue");
        s.trackCreated(endpoint, res);
    }

    const res = s.send(.POST, endpoint, .{ .body = groupJson(s, display, &.{ f[0].id, f[1].id }) }) orelse return;
    if (!s.expectStatus(.must, "RFC7644 §3.3", res, .created, "POST /Groups returns 201")) return;
    s.expectMediaType(res);
    const body = s.json(res);
    const id = j.string(j.field(body, "id")) orelse {
        _ = s.check(.must, "RFC7643 §3.1", false, "created Group has an id", res.body);
        return;
    };
    const path = s.fmt("{s}/{s}", .{ endpoint, id });
    s.created.append(s.arena, path) catch {};
    _ = s.check(.must, "RFC7643 §3", j.hasSchema(body, urn.group), "created Group lists the core Group schema", null);
    _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(body, "meta.resourceType")), "Group"), "meta.resourceType is Group", null);
    _ = s.check(.must, ref, eql(j.string(j.field(body, "displayName")), display), "created Group echoes displayName", null);
    _ = s.check(.must, "RFC7644 §3.3", res.location != null, "201 response includes a Location header", null);

    if (s.fetch("RFC7644 §3.4.1", path)) |got| {
        const members = j.array(j.field(got, "members"));
        _ = s.check(.must, ref, j.findBy(members, "value", f[0].id) != null and j.findBy(members, "value", f[1].id) != null, "Group lists both members", null);
        const member = j.findBy(members, "value", f[0].id);
        _ = s.check(.should, ref, eql(j.string(j.field(member, "type")), "User"), "  member type is User", null);
        const member_ref = j.string(j.field(member, "$ref"));
        _ = s.check(.should, ref, member_ref != null and std.mem.endsWith(u8, member_ref.?, f[0].id), "  member $ref points at the User", member_ref orelse "$ref is missing");
    }
    if (s.fetch("RFC7643 §4.1.2", f[0].path)) |user| {
        const groups = j.array(j.field(user, "groups"));
        _ = s.check(.must, "RFC7643 §4.1.2", j.findBy(groups, "value", id) != null, "User.groups reflects Group membership", null);
    }

    nested(s, endpoint, id);
    projection(s, path);
    queries(s, endpoint, display, f);
    if (s.caps.patch) patchMembers(s, path, f);
    replace(s, path, display, f);
    immutableMemberPut(s, path);
    referentialIntegrity(s, path);

    if (s.send(.DELETE, path, .{})) |del| {
        if (s.expectStatus(.must, "RFC7644 §3.6", del, .no_content, "DELETE /Groups/{id} returns 204")) s.untrack(path);
    }
    if (s.send(.GET, f[0].path, .{})) |user| {
        _ = s.expectStatus(.must, "RFC7644 §3.6", user, .ok, "deleting a Group does not delete its members");
    }
}

/// RFC 7643 §4.2: a Group MAY contain other Groups ("type": "Group").
fn nested(s: *Suite, endpoint: []const u8, parent: []const u8) void {
    const body = s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":{f},\"members\":[{{\"value\":{f},\"type\":\"Group\"}}]}}", .{ urn.group, std.json.fmt(s.fmt("scimcheck-{s}-nested", .{s.run_id}), .{}), std.json.fmt(parent, .{}) });
    const res = s.send(.POST, endpoint, .{ .body = body }) orelse return;
    s.trackCreated(endpoint, res);
    if (s.expectStatus(.may, "RFC7643 §4.2", res, .created, "a Group can have another Group as a member")) {
        const member = j.findBy(j.array(j.field(s.json(res), "members")), "value", parent);
        _ = s.check(.may, "RFC7643 §4.2", member != null, "  the Group member is kept", res.body);
    }
}

fn groupJson(s: *Suite, display: []const u8, members: []const []const u8) []const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (members, 0..) |m, i| {
        if (i > 0) list.append(s.arena, ',') catch {};
        list.print(s.arena, "{{\"value\":{f}}}", .{std.json.fmt(m, .{})}) catch {};
    }
    return s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":{f},\"members\":[{s}]}}", .{ urn.group, std.json.fmt(display, .{}), list.items });
}

fn projection(s: *Suite, path: []const u8) void {
    const ref = "RFC7644 §3.9";
    if (s.send(.GET, s.fmt("{s}?attributes=displayName", .{path}), .{})) |r| {
        if (s.expectStatus(.must, ref, r, .ok, "GET a Group with attributes=displayName returns 200")) {
            _ = s.check(.must, ref, j.field(s.json(r), "members") == null, "  members is omitted", r.body);
        }
    }
    if (s.send(.GET, s.fmt("{s}?excludedAttributes=members", .{path}), .{})) |r| {
        if (s.expectStatus(.must, ref, r, .ok, "GET a Group with excludedAttributes=members returns 200")) {
            const v = s.json(r);
            _ = s.check(.must, ref, j.field(v, "members") == null and j.field(v, "displayName") != null, "  members is omitted and displayName kept", r.body);
        }
    }
}

fn queries(s: *Suite, endpoint: []const u8, display: []const u8, f: [3]check.Fixture) void {
    if (!s.caps.filter) return;
    const ref = "RFC7644 §3.4.2.2";
    s.expectCountAt(endpoint, ref, .must, s.fmt("displayName eq \"{s}\"", .{display}), 1, "filter Groups by displayName");
    s.expectCountAt(endpoint, ref, .must, s.fmt("displayName eq \"{s}\" and members[value eq \"{s}\"]", .{ display, f[1].id }), 1, "filter Groups by members[value eq ...]");
    s.expectCountAt(endpoint, ref, .must, s.fmt("displayName eq \"{s}\" and members.value eq \"{s}\"", .{ display, f[0].id }), 1, "filter Groups by members.value");
    s.expectCountAt(endpoint, ref, .must, s.fmt("displayName eq \"{s}\" and members[value eq \"{s}\"]", .{ display, f[2].id }), 0, "members filter excludes non-members");
}

fn patchMembers(s: *Suite, path: []const u8, f: [3]check.Fixture) void {
    const ref = "RFC7644 §3.5.2";
    const add = s.fmt("{{\"op\":\"add\",\"path\":\"members\",\"value\":[{{\"value\":{f}}}]}}", .{std.json.fmt(f[2].id, .{})});
    s.expectPatch("RFC7644 §3.5.2.1", path, add, "PATCH add a member", null, null);
    if (s.fetch(ref, path)) |v| _ = s.check(.must, "RFC7644 §3.5.2.1", memberList(v).len == 3 and has(v, f[2].id), "  existing members are kept", null);

    const before = s.fetch(ref, path);
    s.expectPatch("RFC7644 §3.5.2.1", path, add, "PATCH add an existing member", null, null);
    if (s.fetch(ref, path)) |v| {
        _ = s.check(.should, "RFC7644 §3.5.2.1", memberList(v).len == 3, "  the member is not duplicated", null);
        _ = s.check(.must, "RFC7644 §3.5.2.1", eql(j.string(j.path(v, "meta.lastModified")), j.string(j.path(before, "meta.lastModified")) orelse ""), "  meta.lastModified is unchanged", null);
    }

    const remove = s.fmt("{{\"op\":\"remove\",\"path\":{f}}}", .{std.json.fmt(s.fmt("members[value eq \"{s}\"]", .{f[0].id}), .{})});
    s.expectPatch("RFC7644 §3.5.2.2", path, remove, "PATCH remove a member by value filter", null, null);
    if (s.fetch(ref, path)) |v| _ = s.check(.must, "RFC7644 §3.5.2.2", !has(v, f[0].id) and has(v, f[1].id) and has(v, f[2].id), "  only that member is removed", null);

    const replace_all = s.fmt("{{\"op\":\"replace\",\"path\":\"members\",\"value\":[{{\"value\":{f}}}]}}", .{std.json.fmt(f[0].id, .{})});
    s.expectPatch("RFC7644 §3.5.2.3", path, replace_all, "PATCH replace all members", null, null);
    if (s.fetch(ref, path)) |v| _ = s.check(.must, "RFC7644 §3.5.2.3", memberList(v).len == 1 and has(v, f[0].id), "  members is exactly the new value", null);

    // RFC 7643 §4.2: a member's value, $ref and type are immutable.
    const retarget = s.fmt("{{\"op\":\"replace\",\"path\":{f},\"value\":{f}}}", .{ std.json.fmt(s.fmt("members[value eq \"{s}\"].value", .{f[0].id}), .{}), std.json.fmt(f[1].id, .{}) });
    if (s.send(.PATCH, path, .{ .body = s.patchJson(retarget) })) |r| {
        s.expectError(.must, "RFC7644 §3.5.2", r, .bad_request, "mutability", "changing an existing member's value returns 400 mutability");
    }

    // Azure AD / Entra style: remove with a value array instead of a filter.
    const remove_value = s.fmt("{{\"op\":\"remove\",\"path\":\"members\",\"value\":[{{\"value\":{f}}}]}}", .{std.json.fmt(f[0].id, .{})});
    if (s.send(.PATCH, path, .{ .body = s.patchJson(remove_value) })) |r| {
        if (s.expectStatusIn(.may, ref, r, &.{ .ok, .no_content }, "PATCH remove members with a value array is accepted")) {
            if (s.fetch(ref, path)) |v| _ = s.check(.may, ref, !has(v, f[0].id), "  the listed member is removed", null);
        }
    }

    s.expectPatch("RFC7644 §3.5.2.1", path, s.fmt("{{\"op\":\"add\",\"path\":\"members\",\"value\":[{{\"value\":{f}}},{{\"value\":{f}}}]}}", .{ std.json.fmt(f[1].id, .{}), std.json.fmt(f[2].id, .{}) }), "PATCH add several members", null, null);
    s.expectPatch("RFC7644 §3.5.2.2", path, "{\"op\":\"remove\",\"path\":\"members\"}", "PATCH remove all members", null, null);
    if (s.fetch(ref, path)) |v| _ = s.check(.must, "RFC7644 §3.5.2.2", memberList(v).len == 0, "  members is empty", null);

    s.expectPatch("RFC7644 §3.5.2.3", path,
        \\{"op":"replace","path":"displayName","value":"scimcheck renamed"}
    , "PATCH replace displayName", "displayName", "scimcheck renamed");
}

fn replace(s: *Suite, path: []const u8, display: []const u8, f: [3]check.Fixture) void {
    const ref = "RFC7644 §3.5.1";
    const res = s.send(.PUT, path, .{ .body = groupJson(s, display, &.{ f[1].id, f[2].id }) }) orelse return;
    if (!s.expectStatus(.must, ref, res, .ok, "PUT /Groups/{id} returns 200")) return;
    if (s.fetch(ref, path)) |v| {
        _ = s.check(.must, ref, eql(j.string(j.field(v, "displayName")), display) and memberList(v).len == 2 and has(v, f[1].id) and has(v, f[2].id), "  displayName and members are replaced", null);
    }
}

/// RFC 7644 §3.5.1: an immutable sub-attribute already set MUST match on
/// replacement, or 400 mutability SHOULD be returned. RFC 7643 §4.2: a
/// Group member's type and $ref are immutable once set.
fn immutableMemberPut(s: *Suite, path: []const u8) void {
    const ref = "RFC7644 §3.5.1";
    const v = s.fetch(ref, path) orelse return;
    const members = memberList(v);
    if (members.len == 0) return s.skip("no Group member to test immutability against");
    const member = members[0];
    const value_id = j.string(j.field(member, "value")) orelse return;
    const display = j.string(j.field(v, "displayName")) orelse "";
    if (j.string(j.field(member, "type"))) |t| {
        const new_type = if (eql(t, "Group")) "User" else "Group";
        const body = s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":{f},\"members\":[{{\"value\":{f},\"type\":{f}}}]}}", .{ urn.group, std.json.fmt(display, .{}), std.json.fmt(value_id, .{}), std.json.fmt(new_type, .{}) });
        if (s.send(.PUT, path, .{ .body = body })) |r| {
            s.expectError(.must, ref, r, .bad_request, "mutability", "PUT changing an existing member's type returns 400 mutability");
        }
        return;
    }
    if (j.string(j.field(member, "$ref"))) |old_ref| {
        const new_ref = s.fmt("{s}-changed", .{old_ref});
        const body = s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":{f},\"members\":[{{\"value\":{f},\"$ref\":{f}}}]}}", .{ urn.group, std.json.fmt(display, .{}), std.json.fmt(value_id, .{}), std.json.fmt(new_ref, .{}) });
        if (s.send(.PUT, path, .{ .body = body })) |r| {
            s.expectError(.must, ref, r, .bad_request, "mutability", "PUT changing an existing member's $ref returns 400 mutability");
        }
        return;
    }
    s.skip("no Group member sub-attribute (type/$ref) is set to test immutability against");
}

/// RFC 7644 §3.6: a service provider MAY remove references to a deleted resource.
fn referentialIntegrity(s: *Suite, path: []const u8) void {
    const temp = s.createUser(.{ .user_name = s.userName("member") }) orelse return;
    const add = s.fmt("{{\"op\":\"add\",\"path\":\"members\",\"value\":[{{\"value\":{f}}}]}}", .{std.json.fmt(temp.id, .{})});
    if (s.caps.patch) {
        const r = s.send(.PATCH, path, .{ .body = s.patchJson(add) }) orelse return;
        if (r.status != .ok and r.status != .no_content) return;
    } else return;
    if (s.send(.DELETE, temp.path, .{})) |del| {
        if (del.status == .no_content) s.untrack(temp.path);
    }
    if (s.fetch("RFC7644 §3.6", path)) |v| {
        _ = s.check(.may, "RFC7644 §3.6", !has(v, temp.id), "deleting a User removes it from Group members", null);
    }
}

fn memberList(v: Value) []const Value {
    return j.array(j.field(v, "members")) orelse &.{};
}

fn has(v: Value, id: []const u8) bool {
    return j.findBy(memberList(v), "value", id) != null;
}
