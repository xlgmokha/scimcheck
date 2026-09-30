//! PATCH (RFC 7644 §3.5.2): add, remove and replace with every path form,
//! multi-valued and primary semantics, ordering, atomicity and errors.
//! Runs against the carol fixture.
const std = @import("std");
const Value = std.json.Value;

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const eql = check.eql;

pub fn run(s: *Suite) void {
    if (!s.caps.patch) return s.skip("patch.supported is false");
    const f = s.requireFixtures() orelse return;
    const path = f[2].path;
    replace(s, path);
    add(s, path);
    multiValued(s, path, f[2].email);
    remove(s, path);
    semantics(s, path);
    errors(s, path);
}

fn replace(s: *Suite, path: []const u8) void {
    const ref = "RFC7644 §3.5.2.3";
    if (s.send(.PATCH, path, .{ .body = s.patchJson("{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"Patched Name\"}") })) |res| {
        if (s.patchOk(ref, res, "replace with a path")) {
            if (res.status == .ok) {
                _ = s.check(.must, "RFC7644 §3.5.2", eql(j.string(j.field(s.json(res), "displayName")), "Patched Name"), "  a 200 response carries the updated resource", res.body);
            }
            if (s.fetch(ref, path)) |v| _ = s.check(.must, ref, eql(j.string(j.field(v, "displayName")), "Patched Name"), "  displayName is \"Patched Name\"", null);
        }
    }
    s.expectPatch(ref, path,
        \\{"op":"replace","value":{"displayName":"Patched Again","nickName":"Babs"}}
    , "replace without a path", "nickName", "Babs");
    s.expectPatch(ref, path,
        \\{"op":"replace","path":"name.givenName","value":"Carla"}
    , "replace a sub-attribute", "name.givenName", "Carla");
    s.expectPatch(ref, path,
        \\{"op":"replace","path":"name","value":{"familyName":"Jansen"}}
    , "replace a complex attribute", "name.familyName", "Jansen");
    if (s.fetch(ref, path)) |v| {
        _ = s.check(.must, ref, eql(j.string(j.path(v, "name.givenName")), "Carla"), "  sub-attributes not in the value are left unchanged", null);
    }
    s.expectPatch(ref, path,
        \\{"op":"replace","path":"active","value":true}
    , "replace a boolean", null, null);
    if (s.fetch(ref, path)) |v| _ = s.check(.must, ref, j.boolean(j.field(v, "active")) == true, "  active is true", null);
    s.expectPatch(ref, path,
        \\{"op":"replace","path":"title","value":"Engineer"}
    , "replace an attribute that has no value adds it", "title", "Engineer");
}

fn add(s: *Suite, path: []const u8) void {
    const ref = "RFC7644 §3.5.2.1";
    s.expectPatch(ref, path,
        \\{"op":"add","path":"displayName","value":"Added Name"}
    , "add to a single-valued attribute replaces it", "displayName", "Added Name");
    s.expectPatch(ref, path,
        \\{"op":"add","value":{"title":"Manager","profileUrl":"https://example.com/carol"}}
    , "add without a path merges the object", "profileUrl", "https://example.com/carol");
    if (s.fetch(ref, path)) |v| {
        _ = s.check(.must, ref, eql(j.string(j.field(v, "title")), "Manager") and j.string(j.field(v, "userName")) != null, "  every attribute in the value is applied and others are kept", null);
    }
    s.expectPatch(ref, path,
        \\{"op":"add","path":"name.middleName","value":"Q"}
    , "add a sub-attribute", "name.middleName", "Q");
    if (s.fetch(ref, path)) |v| _ = s.check(.must, ref, eql(j.string(j.path(v, "name.givenName")), "Carla"), "  sibling sub-attributes are kept", null);
}

fn multiValued(s: *Suite, path: []const u8, work_email: []const u8) void {
    const ref = "RFC7644 §3.5.2";
    s.expectPatch("RFC7644 §3.5.2.1", path,
        \\{"op":"add","path":"emails","value":[{"value":"carol@home.example.com","type":"home"}]}
    , "add to a multi-valued attribute", null, null);
    if (s.fetch(ref, path)) |v| {
        const emails = j.array(j.field(v, "emails"));
        _ = s.check(.must, "RFC7644 §3.5.2.1", j.findBy(emails, "type", "home") != null and j.findBy(emails, "value", work_email) != null, "  the value is appended and existing values are kept", null);
    }
    const before = s.fetch(ref, path);
    s.expectPatch("RFC7644 §3.5.2.1", path,
        \\{"op":"add","path":"emails","value":[{"value":"carol@home.example.com","type":"home"}]}
    , "add a value that is already present", null, null);
    if (s.fetch(ref, path)) |v| {
        _ = s.check(.should, "RFC7644 §3.5.2.1", count(j.array(j.field(v, "emails")), "value", "carol@home.example.com") == 1, "  the value is not duplicated", null);
        const modified = j.string(j.path(before, "meta.lastModified")) orelse "";
        _ = s.check(.must, "RFC7644 §3.5.2.1", check.eql(j.string(j.path(v, "meta.lastModified")), modified), "  meta.lastModified is unchanged", s.fmt("was {s}, now {?s}", .{ modified, j.string(j.path(v, "meta.lastModified")) }));
    }
    s.expectPatch("RFC7644 §3.5.2.1", path,
        \\{"op":"add","path":"emails[type eq \"work\"].display","value":"Work"}
    , "add a sub-attribute through a value filter", null, null);
    if (s.fetch(ref, path)) |v| {
        const work = j.findBy(j.array(j.field(v, "emails")), "type", "work");
        _ = s.check(.must, "RFC7644 §3.5.2.1", eql(j.string(j.field(work, "display")), "Work") and eql(j.string(j.field(work, "value")), work_email), "  only the matching value gains display", null);
    }
    s.expectPatch("RFC7644 §3.5.2.2", path,
        \\{"op":"remove","path":"emails[type eq \"work\"].display"}
    , "remove a sub-attribute through a value filter", null, null);
    if (s.fetch(ref, path)) |v| {
        const work = j.findBy(j.array(j.field(v, "emails")), "type", "work");
        _ = s.check(.must, "RFC7644 §3.5.2.2", j.field(work, "display") == null and eql(j.string(j.field(work, "value")), work_email), "  only display is removed from the matching value", null);
    }
    s.expectPatch("RFC7644 §3.5.2.3", path,
        \\{"op":"replace","path":"emails[type eq \"home\"].value","value":"carol@elsewhere.example.com"}
    , "replace a sub-attribute through a value filter", null, null);
    if (s.fetch(ref, path)) |v| {
        const home = j.findBy(j.array(j.field(v, "emails")), "type", "home");
        _ = s.check(.must, "RFC7644 §3.5.2.3", eql(j.string(j.field(home, "value")), "carol@elsewhere.example.com"), "  the matching value is updated", null);
    }
    s.expectPatch("RFC7644 §3.5.2.3", path,
        \\{"op":"replace","path":"emails[type eq \"work\" and primary eq true].value","value":"carol@work.example.com"}
    , "replace through a filter with and", null, null);
    if (s.fetch(ref, path)) |v| {
        _ = s.check(.must, "RFC7644 §3.5.2.3", j.findBy(j.array(j.field(v, "emails")), "value", "carol@work.example.com") != null, "  the primary work email is updated", null);
    }
    if (s.send(.PATCH, path, .{ .body = s.patchJson("{\"op\":\"replace\",\"path\":\"emails[type eq \\\"nonexistent\\\"].value\",\"value\":\"x@example.com\"}") })) |res| {
        s.expectError(.must, "RFC7644 §3.5.2.3", res, .bad_request, "noTarget", "replace through a filter that matches nothing returns 400 noTarget");
    }

    // RFC 7644 §3.5.2: setting primary on one value clears it on the others.
    s.expectPatch("RFC7644 §3.5.2", path,
        \\{"op":"add","path":"emails","value":[{"value":"carol@primary.example.com","type":"other","primary":true}]}
    , "add a new primary value", null, null);
    if (s.fetch(ref, path)) |v| {
        const emails = j.array(j.field(v, "emails"));
        const new = j.findBy(emails, "value", "carol@primary.example.com");
        _ = s.check(.must, "RFC7644 §3.5.2", check.primaryCount(emails) == 1 and j.boolean(j.field(new, "primary")) == true, "  the new value is the only primary", s.fmt("{f}", .{std.json.fmt(emails, .{})}));
    }

    s.expectPatch("RFC7644 §3.5.2.3", path,
        \\{"op":"replace","path":"emails","value":[{"value":"carol@only.example.com","type":"work","primary":true}]}
    , "replace a whole multi-valued attribute", null, null);
    if (s.fetch(ref, path)) |v| {
        const emails = j.array(j.field(v, "emails"));
        _ = s.check(.must, "RFC7644 §3.5.2.3", check.lenOf(emails) == 1 and j.findBy(emails, "value", "carol@only.example.com") != null, "  the existing values are replaced", null);
    }
}

fn remove(s: *Suite, path: []const u8) void {
    const ref = "RFC7644 §3.5.2.2";
    s.expectPatch("RFC7644 §3.5.2.1", path,
        \\{"op":"add","path":"phoneNumbers","value":[{"value":"555-0100","type":"work"},{"value":"555-0101","type":"mobile"}]}
    , "add phoneNumbers", null, null);
    // RFC 7644 Table 9: noTarget "occurs when the specified path value
    // contains a filter that yields no match".
    if (s.send(.PATCH, path, .{ .body = s.patchJson("{\"op\":\"remove\",\"path\":\"phoneNumbers[type eq \\\"pager\\\"]\"}") })) |res| {
        s.expectError(.should, "RFC7644 §3.12", res, .bad_request, "noTarget", "remove through a filter that matches nothing returns 400 noTarget");
        if (s.fetch(ref, path)) |v| _ = s.check(.must, ref, check.lenOf(j.array(j.field(v, "phoneNumbers"))) == 2, "  no value is removed", null);
    }
    s.expectPatch(ref, path,
        \\{"op":"remove","path":"phoneNumbers[type eq \"mobile\"]"}
    , "remove through a value filter", null, null);
    if (s.fetch(ref, path)) |v| {
        const phones = j.array(j.field(v, "phoneNumbers"));
        _ = s.check(.must, ref, j.findBy(phones, "type", "mobile") == null and j.findBy(phones, "type", "work") != null, "  only the matching value is removed", null);
    }
    s.expectPatch(ref, path,
        \\{"op":"remove","path":"phoneNumbers"}
    , "remove a whole multi-valued attribute", null, null);
    if (s.fetch(ref, path)) |v| _ = s.check(.must, ref, check.lenOf(j.array(j.field(v, "phoneNumbers"))) == 0, "  phoneNumbers is gone", null);
    s.expectPatch(ref, path,
        \\{"op":"remove","path":"nickName"}
    , "remove a single-valued attribute", null, null);
    if (s.fetch(ref, path)) |v| _ = s.check(.must, ref, j.field(v, "nickName") == null, "  nickName is gone", null);
    s.expectPatch(ref, path,
        \\{"op":"remove","path":"name.middleName"}
    , "remove a sub-attribute", null, null);
    if (s.fetch(ref, path)) |v| {
        _ = s.check(.must, ref, j.path(v, "name.middleName") == null and j.path(v, "name.givenName") != null, "  only middleName is removed", null);
    }
}

fn semantics(s: *Suite, path: []const u8) void {
    const ref = "RFC7644 §3.5.2";
    s.expectPatch(ref, path,
        \\{"op":"replace","path":"title","value":"First"},{"op":"replace","path":"title","value":"Second"}
    , "operations are applied in order", "title", "Second");

    const before = s.fetch(ref, path) orelse return;
    const ops =
        \\{"op":"replace","path":"displayName","value":"Atomic"},{"op":"replace","path":"emails[type eq]","value":"x"}
    ;
    if (s.send(.PATCH, path, .{ .body = s.patchJson(ops) })) |res| {
        _ = s.expectStatus(.must, ref, res, .bad_request, "a request with one invalid operation returns 400");
        if (s.fetch(ref, path)) |after| {
            _ = s.check(.must, ref, eql(j.string(j.field(after, "displayName")), j.string(j.field(before, "displayName")) orelse ""), "  the request is atomic: no operation is applied", null);
        }
    }
    s.expectPatch(ref, path,
        \\{"op":"Replace","path":"displayName","value":"Case Insensitive Op"}
    , "op values in another case (Replace)", "displayName", "Case Insensitive Op");
}

/// RFC 7644 §3.5.2: a PatchOp MUST list its schema and one or more
/// operations, and an operation that is not compatible with an attribute's
/// mutability or schema SHALL return an error.
fn errors(s: *Suite, path: []const u8) void {
    const ref = "RFC7644 §3.5.2";
    const Case = struct { []const u8, ?[]const u8, []const u8, check.Level };
    const cases = [_]Case{
        .{ "{\"op\":\"remove\"}", "noTarget", "remove without a path returns 400 noTarget", .must },
        .{ "{\"op\":\"bogus\",\"path\":\"displayName\",\"value\":\"x\"}", null, "an unknown op returns 400", .must },
        .{ "{\"op\":\"replace\",\"path\":\"emails[type eq]\",\"value\":\"x\"}", "invalidPath", "a malformed path returns 400 invalidPath", .must },
        .{ "{\"op\":\"replace\",\"path\":\"id\",\"value\":\"new-id\"}", "mutability", "replacing a readOnly attribute (id) returns 400 mutability", .must },
        .{ "{\"op\":\"add\",\"path\":\"groups\",\"value\":[{\"value\":\"g\"}]}", "mutability", "adding to a readOnly attribute (groups) returns 400 mutability", .must },
        .{ "{\"op\":\"remove\",\"path\":\"userName\"}", "mutability", "removing a required attribute returns 400 mutability", .must },
        .{ "{\"op\":\"add\",\"path\":\"displayName\"}", null, "add without a value returns 400", .must },
        .{ "{\"op\":\"replace\",\"path\":\"active\",\"value\":\"yes\"}", null, "a value of the wrong type returns 400", .must },
        .{ "{\"op\":\"add\",\"path\":\"x509Certificates\",\"value\":[{\"value\":\"!!!not base64\"}]}", null, "a binary value that is not base64 returns 400", .must },
    };
    for (cases) |c| {
        if (s.send(.PATCH, path, .{ .body = s.patchJson(c[0]) })) |res| s.expectError(c[3], ref, res, .bad_request, c[1], c[2]);
    }
    if (s.send(.PATCH, path, .{ .body = "{\"Operations\":[{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"x\"}]}" })) |res| {
        _ = s.expectStatus(.must, ref, res, .bad_request, "a PatchOp without schemas returns 400");
    }
    if (s.send(.PATCH, path, .{ .body = s.patchJson("") })) |res| {
        _ = s.expectStatus(.must, ref, res, .bad_request, "a PatchOp with no Operations returns 400");
    }
    if (s.send(.PATCH, path, .{ .body = "{\"schemas\": [" })) |res| {
        s.expectError(.must, "RFC7644 §3.12", res, .bad_request, "invalidSyntax", "malformed PATCH JSON returns 400 invalidSyntax");
    }
}

fn count(items: ?[]const Value, key: []const u8, expected: []const u8) usize {
    var n: usize = 0;
    for (items orelse &.{}) |item| {
        if (eql(j.string(j.field(item, key)), expected)) n += 1;
    }
    return n;
}
