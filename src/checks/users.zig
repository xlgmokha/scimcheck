//! User create, retrieve, replace and delete (RFC 7644 §3.3-3.6) and the
//! common attributes and User schema rules of RFC 7643 §3.1 and §4.1.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Client = @import("../Client.zig");
const Suite = check.Suite;
const urn = check.urn;
const eql = check.eql;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.3";
    const user_name = s.userName("crud");
    const res = s.send(.POST, s.users_endpoint, .{ .body = s.userJson(.{ .user_name = user_name }) }) orelse return;
    if (!s.expectStatus(.must, ref, res, .created, "POST /Users returns 201")) return;
    s.expectMediaType(res);
    const body = s.json(res);
    const id = j.string(j.field(body, "id")) orelse {
        _ = s.check(.must, "RFC7643 §3.1", false, "created User has an id", res.body);
        return;
    };
    const path = s.fmt("{s}/{s}", .{ s.users_endpoint, id });
    s.created.append(s.arena, path) catch {};

    _ = s.check(.must, "RFC7643 §3.1", id.len > 0 and !std.ascii.eqlIgnoreCase(id, "bulkId"), "created User has an id", null);
    _ = s.check(.must, ref, res.location != null, "201 response includes a Location header", null);
    const meta_location = j.string(j.path(body, "meta.location"));
    _ = s.check(.must, ref, meta_location != null, "created User has meta.location", null);
    if (res.location != null and meta_location != null) {
        _ = s.check(.should, ref, std.mem.eql(u8, res.location.?, meta_location.?), "Location header equals meta.location", s.fmt("{s} vs {s}", .{ res.location.?, meta_location.? }));
    }
    if (res.content_location) |loc| {
        _ = s.check(.must, "RFC7643 §3.1", eql(meta_location, loc), "meta.location equals the Content-Location header", null);
    }
    _ = s.check(.must, "RFC7643 §3", j.hasSchema(body, urn.user), "created User lists the core User schema", null);
    _ = s.check(.must, "RFC7643 §4.1", eql(j.string(j.field(body, "userName")), user_name), "created User echoes userName", null);
    _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(body, "meta.resourceType")), "User"), "meta.resourceType is User", null);
    _ = s.check(.must, "RFC7643 §2.3.5", check.isDateTime(j.string(j.path(body, "meta.created"))), "meta.created is a dateTime", null);
    _ = s.check(.must, "RFC7643 §2.3.5", check.isDateTime(j.string(j.path(body, "meta.lastModified"))), "meta.lastModified is a dateTime", null);
    _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(body, "meta.lastModified")), j.string(j.path(body, "meta.created")) orelse ""), "an unmodified User has meta.lastModified equal to meta.created", null);
    _ = s.check(.must, "RFC7643 §4.1.1", j.field(body, "password") == null, "password is never returned", null);
    _ = s.check(.must, "RFC7643 §2.3.2", j.boolean(j.field(body, "active")) == true, "active is returned as a JSON boolean", null);
    if (s.caps.etag) {
        _ = s.check(.must, "RFC7644 §3.14", res.etag != null, "201 response includes an ETag header", null);
        if (res.etag) |e| _ = s.check(.should, "RFC7644 §3.14", eql(j.string(j.path(body, "meta.version")), e), "meta.version equals the ETag header", null);
    }

    uniqueness(s, user_name);
    readOnlyInput(s);
    requestFormat(s);
    primary(s);
    unassigned(s);
    everyAttribute(s);
    caseExactValue(s);
    addressCountry(s);
    groupsReadOnly(s);

    if (s.send(.GET, path, .{})) |got| {
        if (s.expectStatus(.must, "RFC7644 §3.4.1", got, .ok, "GET /Users/{id} returns 200")) {
            s.expectMediaType(got);
            const g = s.json(got);
            _ = s.check(.must, "RFC7644 §3.4.1", eql(j.string(j.field(g, "id")), id), "retrieved User has the same id", null);
            _ = s.check(.must, "RFC7643 §4.1.1", j.field(g, "password") == null, "password is never returned", null);
            _ = s.check(.must, "RFC7643 §4.1", eql(j.string(j.path(g, "name.givenName")), "Barbara") and eql(j.string(j.field(g, "externalId")), user_name), "retrieved User keeps the submitted attributes", null);
            if (got.content_location) |loc| {
                _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(g, "meta.location")), loc), "meta.location equals the Content-Location header", null);
            }
        }
    }

    replace(s, path, id, user_name, res);

    if (s.send(.DELETE, path, .{})) |del| {
        if (s.expectStatus(.must, "RFC7644 §3.6", del, .no_content, "DELETE /Users/{id} returns 204")) s.untrack(path);
        _ = s.check(.should, "RFC9110 §15.3.5", del.body.len == 0, "204 response has no body", null);
    }
    if (s.send(.GET, path, .{})) |gone| {
        s.expectError(.must, "RFC7644 §3.6", gone, .not_found, null, "GET a deleted User returns 404");
    }
    if (s.send(.DELETE, path, .{})) |again| {
        s.expectError(.must, "RFC7644 §3.6", again, .not_found, null, "DELETE a deleted User returns 404");
    }
    if (s.caps.filter) {
        s.expectCount("RFC7644 §3.6", .must, s.fmt("userName eq \"{s}\"", .{user_name}), 0, "a deleted User is omitted from queries");
    }
    // RFC 7644 §3.6: a deleted resource is not considered in uniqueness checks.
    if (s.send(.POST, s.users_endpoint, .{ .body = s.userJson(.{ .user_name = user_name }) })) |again| {
        s.trackCreated(s.users_endpoint, again);
        _ = s.expectStatus(.should, "RFC7644 §3.6", again, .created, "the userName of a deleted User can be reused");
    }
}

fn uniqueness(s: *Suite, user_name: []const u8) void {
    const ref = "RFC7644 §3.3";
    if (s.send(.POST, s.users_endpoint, .{ .body = s.userJson(.{ .user_name = user_name }) })) |dup| {
        s.expectError(.must, ref, dup, .conflict, "uniqueness", "POST a duplicate userName returns 409 uniqueness");
        s.trackCreated(s.users_endpoint, dup);
    }
    // RFC 7643 §4.1: userName MUST be unique, so a PUT or PATCH cannot take one in use.
    if (s.createUser(.{ .user_name = s.userName("other") })) |other| {
        if (s.send(.PUT, other.path, .{ .body = s.userJson(.{ .user_name = user_name }) })) |res| {
            s.expectError(.must, "RFC7644 §3.5.1", res, .conflict, "uniqueness", "PUT a userName already in use returns 409 uniqueness");
        }
        if (s.caps.patch) {
            const op = s.fmt("{{\"op\":\"replace\",\"path\":\"userName\",\"value\":{f}}}", .{std.json.fmt(user_name, .{})});
            if (s.send(.PATCH, other.path, .{ .body = s.patchJson(op) })) |res| {
                s.expectError(.must, "RFC7644 §3.5.2", res, .conflict, "uniqueness", "PATCH a userName already in use returns 409 uniqueness");
            }
        }
    }
    const upper = std.ascii.allocUpperString(s.arena, user_name) catch user_name;
    if (s.send(.POST, s.users_endpoint, .{ .body = s.userJson(.{ .user_name = upper }) })) |dup| {
        _ = s.expectStatus(.should, "RFC7643 §4.1", dup, .conflict, "userName uniqueness ignores case (caseExact false)");
        s.trackCreated(s.users_endpoint, dup);
    }
}

/// readOnly attributes in a request body "SHALL be ignored" (RFC 7644 §3.3),
/// so the request succeeds without them.
fn readOnlyInput(s: *Suite) void {
    const ref = "RFC7644 §3.3";
    const body = s.userJson(.{
        .user_name = s.userName("readonly"),
        .extra = "\"id\":\"scimcheck-client-id\",\"meta\":{\"created\":\"2000-01-01T00:00:00Z\",\"resourceType\":\"Fake\"},",
    });
    const res = s.send(.POST, s.users_endpoint, .{ .body = body }) orelse return;
    s.trackCreated(s.users_endpoint, res);
    if (!s.expectStatus(.must, ref, res, .created, "POST with client-supplied id and meta returns 201")) return;
    const created = s.json(res);
    _ = s.check(.must, ref, !eql(j.string(j.field(created, "id")), "scimcheck-client-id"), "the service provider assigns the id", null);
    _ = s.check(.must, ref, eql(j.string(j.path(created, "meta.resourceType")), "User"), "client-supplied meta.resourceType is ignored", null);
    _ = s.check(.must, ref, !eql(j.string(j.path(created, "meta.created")), "2000-01-01T00:00:00Z"), "client-supplied meta.created is ignored", null);
}

/// RFC 7643 §2.1 (case-insensitive names) and RFC 7644 §3.1, §3.8 and §8.1 (media types).
fn requestFormat(s: *Suite) void {
    if (s.send(.GET, s.users_endpoint, .{ .accept = Client.media_type })) |res| {
        if (s.expectStatus(.must, "RFC7644 §3.8", res, .ok, "Accept: application/scim+json is supported")) s.expectMediaType(res);
    }
    if (s.send(.GET, s.users_endpoint, .{ .accept = "application/json" })) |res| {
        _ = s.expectStatus(.should, "RFC7644 §3.8", res, .ok, "Accept: application/json is supported");
    }
    const name = s.userName("case");
    const shouting = s.fmt("{{\"SCHEMAS\":[\"{s}\"],\"USERNAME\":{f},\"Name\":{{\"GIVENNAME\":\"Loud\"}}}}", .{ urn.user, std.json.fmt(name, .{}) });
    if (s.send(.POST, s.users_endpoint, .{ .body = shouting })) |res| {
        s.trackCreated(s.users_endpoint, res);
        if (s.expectStatus(.must, "RFC7643 §2.1", res, .created, "attribute names in requests are case-insensitive")) {
            const body = s.json(res);
            _ = s.check(.must, "RFC7643 §2.1", eql(j.string(j.field(body, "userName")), name) and eql(j.string(j.path(body, "name.givenName")), "Loud"), "  USERNAME and name.GIVENNAME are stored", res.body);
        }
    }
    const plain = s.userJson(.{ .user_name = s.userName("json") });
    if (s.send(.POST, s.users_endpoint, .{ .body = plain, .content_type = "application/json" })) |res| {
        s.trackCreated(s.users_endpoint, res);
        _ = s.expectStatus(.should, "RFC7644 §8.1", res, .created, "requests with Content-Type application/json are accepted");
    }
}

/// A value for every core User attribute (RFC 7643 §4.1), shaped like the
/// full representation in RFC 7643 §8.2.
const full_user = [_]struct { []const u8, []const u8 }{
    .{ "name", "{\"formatted\":\"Ms. Barbara J Jensen III\",\"familyName\":\"Jensen\",\"givenName\":\"Barbara\",\"middleName\":\"Jane\",\"honorificPrefix\":\"Ms.\",\"honorificSuffix\":\"III\"}" },
    .{ "displayName", "\"Babs Jensen\"" },
    .{ "nickName", "\"Babs\"" },
    .{ "profileUrl", "\"https://login.example.com/bjensen\"" },
    .{ "title", "\"Tour Guide\"" },
    .{ "userType", "\"Employee\"" },
    .{ "preferredLanguage", "\"en-US\"" },
    .{ "locale", "\"en-US\"" },
    .{ "timezone", "\"America/Los_Angeles\"" },
    .{ "active", "true" },
    .{ "emails", "[{\"value\":\"bjensen@example.com\",\"type\":\"work\",\"primary\":true}]" },
    .{ "phoneNumbers", "[{\"value\":\"555-555-5555\",\"type\":\"work\"}]" },
    .{ "ims", "[{\"value\":\"someaimhandle\",\"type\":\"aim\"}]" },
    .{ "photos", "[{\"value\":\"https://photos.example.com/profilephoto/72930000000Ccne/F\",\"type\":\"photo\"}]" },
    .{ "addresses", "[{\"type\":\"work\",\"streetAddress\":\"100 Universal City Plaza\",\"locality\":\"Hollywood\",\"region\":\"CA\",\"postalCode\":\"91608\",\"country\":\"US\",\"formatted\":\"100 Universal City Plaza\\nHollywood, CA 91608 USA\",\"primary\":true}]" },
    .{ "entitlements", "[{\"value\":\"scimcheck entitlement\"}]" },
    .{ "roles", "[{\"value\":\"scimcheck role\"}]" },
    .{ "x509Certificates", "[{\"value\":\"MIIDQzCCAqygAwIBAgICEAAwDQYJKoZIhvcNAQEFBQAw\"}]" },
};

/// RFC 7643 §7: an attribute the User schema declares as writable and
/// "returned": "default" is stored and returned. Only attributes the
/// service provider publishes are sent.
fn everyAttribute(s: *Suite) void {
    const ref = "RFC7643 §7";
    const attributes = j.array(j.field(s.user_schema, "attributes")) orelse return s.skip("the User schema is not published, so its attributes are unknown");
    var members: std.ArrayList(u8) = .empty;
    var sent: std.ArrayList([]const u8) = .empty;
    for (full_user) |entry| {
        const name, const value = entry;
        const definition = j.findBy(attributes, "name", name) orelse continue;
        const mutability = j.string(j.field(definition, "mutability")) orelse "readWrite";
        const returned = j.string(j.field(definition, "returned")) orelse "default";
        if (!(eql(mutability, "readWrite") or eql(mutability, "immutable"))) continue;
        if (!(eql(returned, "default") or eql(returned, "always"))) continue;
        members.print(s.arena, ",\"{s}\":{s}", .{ name, value }) catch {};
        sent.append(s.arena, name) catch {};
    }
    if (sent.items.len == 0) return s.skip("the User schema declares none of the RFC 7643 §4.1 attributes as writable and returned");
    const body = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f}{s}}}", .{ urn.user, std.json.fmt(s.userName("everything"), .{}), members.items });
    const res = s.send(.POST, s.users_endpoint, .{ .body = body }) orelse return;
    s.trackCreated(s.users_endpoint, res);
    if (!s.expectStatus(.must, "RFC7644 §3.3", res, .created, "POST a User with every published core attribute returns 201")) return;
    const id = j.string(j.field(s.json(res), "id")) orelse return;
    const got = s.fetch("RFC7644 §3.4.1", s.fmt("{s}/{s}", .{ s.users_endpoint, id })) orelse return;
    for (sent.items) |name| {
        const v = j.field(got, name);
        _ = s.check(.must, ref, v != null and v.? != .null, s.fmt("  {s} is stored and returned", .{name}), s.fmt("{f}", .{std.json.fmt(got, .{})}));
    }
}

/// RFC 7643 §2.5: assigning null, or an empty array to a multi-valued
/// attribute, makes the attribute unassigned.
fn unassigned(s: *Suite) void {
    const ref = "RFC7643 §2.5";
    const user_name = s.userName("unassigned");
    const body = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f},\"nickName\":null,\"emails\":[]}}", .{ urn.user, std.json.fmt(user_name, .{}) });
    const res = s.send(.POST, s.users_endpoint, .{ .body = body }) orelse return;
    s.trackCreated(s.users_endpoint, res);
    if (!s.expectStatus(.must, ref, res, .created, "POST with a null value and an empty array returns 201")) return;
    const v = s.json(res);
    const nick = j.field(v, "nickName");
    _ = s.check(.must, ref, nick == null or nick.? == .null, "  a null value leaves the attribute unassigned", res.body);
    _ = s.check(.must, ref, check.lenOf(j.array(j.field(v, "emails"))) == 0, "  an empty array leaves the attribute unassigned", res.body);
    if (s.caps.filter) {
        s.expectCount(ref, .must, s.fmt("userName eq \"{s}\" and (nickName pr or emails pr)", .{user_name}), 0, "  unassigned attributes do not match pr");
    }
}

/// RFC 7643 §2.4: "primary" is true for at most one value, checked on every
/// multi-valued User attribute that has a "primary" sub-attribute.
const primary_attrs = [_]struct { []const u8, []const u8 }{
    .{ "phoneNumbers", "[{\"value\":\"555-0100\",\"type\":\"work\",\"primary\":true},{\"value\":\"555-0101\",\"type\":\"home\",\"primary\":true}]" },
    .{ "ims", "[{\"value\":\"handle1\",\"type\":\"aim\",\"primary\":true},{\"value\":\"handle2\",\"type\":\"gtalk\",\"primary\":true}]" },
    .{ "photos", "[{\"value\":\"https://photos.example.com/a.jpg\",\"type\":\"photo\",\"primary\":true},{\"value\":\"https://photos.example.com/b.jpg\",\"type\":\"thumbnail\",\"primary\":true}]" },
    .{ "entitlements", "[{\"value\":\"scimcheck-ent-a\",\"primary\":true},{\"value\":\"scimcheck-ent-b\",\"primary\":true}]" },
    .{ "roles", "[{\"value\":\"scimcheck-role-a\",\"primary\":true},{\"value\":\"scimcheck-role-b\",\"primary\":true}]" },
    .{ "x509Certificates", "[{\"value\":\"MTIz\",\"primary\":true},{\"value\":\"NDU2\",\"primary\":true}]" },
};

fn primary(s: *Suite) void {
    const ref = "RFC7643 §2.4";
    for (primary_attrs) |entry| {
        const name, const values = entry;
        const body = s.userJson(.{
            .user_name = s.userName(s.fmt("primary-{s}", .{name})),
            .extra = s.fmt("\"{s}\":{s},", .{ name, values }),
        });
        const res = s.send(.POST, s.users_endpoint, .{ .body = body }) orelse continue;
        s.trackCreated(s.users_endpoint, res);
        if (res.status == .bad_request) {
            _ = s.check(.must, ref, true, s.fmt("  {s}: two primary values are rejected or normalized", .{name}), null);
            s.expectErrorBody(res, "invalidValue");
            continue;
        }
        if (!s.expectStatus(.must, ref, res, .created, s.fmt("  {s}: POST with two primary values returns 400 or 201", .{name}))) continue;
        _ = s.check(.must, ref, check.primaryCount(j.array(j.field(s.json(res), name))) <= 1, s.fmt("  {s}: at most one value is primary", .{name}), res.body);
    }
}

/// RFC 7643 §7: a caseExact attribute keeps the case it was submitted with.
fn caseExactValue(s: *Suite) void {
    const ref = "RFC7643 §7";
    const mixed = "MiXeD-CaSe-ExternalId";
    const res = s.send(.POST, s.users_endpoint, .{ .body = s.userJson(.{ .user_name = s.userName("caseexact"), .external_id = mixed }) }) orelse return;
    s.trackCreated(s.users_endpoint, res);
    if (!s.expectStatus(.must, ref, res, .created, "POST with a mixed-case externalId returns 201")) return;
    const id = j.string(j.field(s.json(res), "id")) orelse return;
    const got = s.fetch(ref, s.fmt("{s}/{s}", .{ s.users_endpoint, id })) orelse return;
    _ = s.check(.must, ref, eql(j.string(j.field(got, "externalId")), mixed), "  externalId keeps the submitted case", s.fmt("{f}", .{std.json.fmt(got, .{})}));
}

/// RFC 7643 §4.1.2: an address's country value MUST be ISO 3166-1 alpha-2.
fn addressCountry(s: *Suite) void {
    const ref = "RFC7643 §4.1.2";
    const body = s.userJson(.{
        .user_name = s.userName("country"),
        .extra = "\"addresses\":[{\"type\":\"work\",\"country\":\"United States\"}],",
    });
    const res = s.send(.POST, s.users_endpoint, .{ .body = body }) orelse return;
    s.trackCreated(s.users_endpoint, res);
    if (res.status == .bad_request) {
        _ = s.check(.must, ref, true, "  a non-alpha-2 country is rejected", null);
        return;
    }
    if (!s.expectStatus(.must, ref, res, .created, "  POST with a non-alpha-2 country returns 400 or 201")) return;
    const addresses = j.array(j.field(s.json(res), "addresses"));
    const country = if (addresses != null and addresses.?.len > 0) j.string(j.field(addresses.?[0], "country")) else null;
    _ = s.check(.must, ref, country != null and country.?.len == 2, "  a non-alpha-2 country is normalized to two letters", country);
}

/// RFC 7643 §4.1.2: User.groups is readOnly - membership changes go through
/// the Group resource, not a direct write here.
fn groupsReadOnly(s: *Suite) void {
    const ref = "RFC7643 §4.1.2";
    const body = s.userJson(.{
        .user_name = s.userName("groupsreadonly"),
        .extra = "\"groups\":[{\"value\":\"scimcheck-fake-group\",\"display\":\"Fake\"}],",
    });
    const res = s.send(.POST, s.users_endpoint, .{ .body = body }) orelse return;
    s.trackCreated(s.users_endpoint, res);
    if (!s.expectStatus(.must, ref, res, .created, "POST with a client-supplied groups value returns 201")) return;
    const groups = j.array(j.field(s.json(res), "groups"));
    _ = s.check(.must, ref, j.findBy(groups, "value", "scimcheck-fake-group") == null, "  a client-supplied groups value is ignored", res.body);
}

fn replace(s: *Suite, path: []const u8, id: []const u8, user_name: []const u8, created: Client.Response) void {
    const ref = "RFC7644 §3.5.1";
    const with_nick = s.userJson(.{ .user_name = user_name, .display_name = "Babs Jensen", .extra = "\"nickName\":\"Babs\",\"id\":\"scimcheck-other-id\",\"meta\":{\"created\":\"2000-01-01T00:00:00Z\"}," });
    const put = s.send(.PUT, path, .{ .body = with_nick }) orelse return;
    if (!s.expectStatus(.must, ref, put, .ok, "PUT /Users/{id} returns 200")) return;
    s.expectMediaType(put);
    const p = s.json(put);
    const before = s.json(created);
    _ = s.check(.must, ref, eql(j.string(j.field(p, "displayName")), "Babs Jensen") and eql(j.string(j.field(p, "nickName")), "Babs"), "PUT replaces attribute values", put.body);
    _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.field(p, "id")), id), "PUT ignores an id in the body", null);
    _ = s.check(.must, "RFC7643 §4.1.1", j.field(p, "password") == null, "PUT does not return password", null);
    _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(p, "meta.created")), j.string(j.path(before, "meta.created")) orelse ""), "meta.created is unchanged by PUT, even when the body sends one", null);
    _ = s.check(.should, "RFC7643 §3.1", !eql(j.string(j.path(p, "meta.lastModified")), j.string(j.path(before, "meta.lastModified")) orelse ""), "meta.lastModified changes after PUT", null);
    if (s.caps.etag and created.etag != null and put.etag != null) {
        _ = s.check(.should, "RFC7644 §3.14", !std.mem.eql(u8, created.etag.?, put.etag.?), "ETag changes after PUT", null);
    }

    // PUT replaces the whole resource: an attribute left out is cleared.
    if (s.send(.PUT, path, .{ .body = s.userJson(.{ .user_name = user_name, .display_name = "Babs Jensen" }) })) |again| {
        if (s.expectStatus(.must, ref, again, .ok, "PUT without nickName returns 200")) {
            // RFC 7644 §3.5.1: an omitted attribute MAY be cleared or defaulted, both allowed.
            _ = s.check(.may, ref, j.field(s.json(again), "nickName") == null, "  PUT clears attributes it does not include", again.body);
        }
    }
    const without_user_name = s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":\"x\"}}", .{urn.user});
    if (s.send(.PUT, path, .{ .body = without_user_name })) |bad| {
        s.expectError(.must, "RFC7643 §4.1", bad, .bad_request, "invalidValue", "PUT without the required userName returns 400 invalidValue");
    }
}
