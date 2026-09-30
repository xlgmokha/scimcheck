//! RFC 7644 §4 discovery endpoints and the RFC 7643 §5-7 documents they
//! return. Also records the endpoints and features later sections rely on.
const std = @import("std");
const Value = std.json.Value;

const check = @import("../check.zig");
const j = @import("../json.zig");
const Client = @import("../Client.zig");
const Suite = check.Suite;
const urn = check.urn;
const eql = check.eql;

pub fn run(s: *Suite) void {
    serviceProviderConfig(s);
    const types = resourceTypes(s);
    const schemas = schemaList(s);
    crossReference(s, types, schemas);
    individualEndpoints(s, types, schemas);
    queryParamsIgnored(s, types, schemas);

    if (s.send(.GET, "/ResourceTypes?filter=name%20eq%20%22User%22", .{})) |res| {
        s.expectError(.should, "RFC7644 §4", res, .forbidden, null, "filtering /ResourceTypes returns 403");
    }
    if (s.send(.GET, "/Schemas?filter=id%20pr", .{})) |res| {
        s.expectError(.should, "RFC7644 §4", res, .forbidden, null, "filtering /Schemas returns 403");
    }
}

/// RFC 7644 §4: pagination/sorting query parameters SHALL be ignored on the
/// discovery endpoints (filtering has its own 403 carve-out, checked below).
fn queryParamsIgnored(s: *Suite, types: []const Value, schemas: []const Value) void {
    const ref = "RFC7644 §4";
    if (types.len > 1) {
        if (s.send(.GET, "/ResourceTypes?count=1", .{})) |res| {
            if (s.expectList(ref, res, "GET /ResourceTypes?count=1 returns a ListResponse")) |body| {
                const resources = j.array(j.field(body, "Resources")) orelse &.{};
                _ = s.check(.must, ref, resources.len == types.len, "pagination parameters on /ResourceTypes are ignored", null);
            }
        }
    }
    if (schemas.len > 1) {
        if (s.send(.GET, "/Schemas?count=1", .{})) |res| {
            if (s.expectList(ref, res, "GET /Schemas?count=1 returns a ListResponse")) |body| {
                const resources = j.array(j.field(body, "Resources")) orelse &.{};
                _ = s.check(.must, ref, resources.len == schemas.len, "pagination parameters on /Schemas are ignored", null);
            }
        }
    }
}

fn serviceProviderConfig(s: *Suite) void {
    const ref = "RFC7643 §5";
    const res = s.send(.GET, "/ServiceProviderConfig", .{}) orelse return;
    if (!s.expectStatus(.must, "RFC7644 §4", res, .ok, "GET /ServiceProviderConfig returns 200")) return;
    s.expectMediaType(res);
    const body = s.json(res);
    _ = s.check(.must, "RFC7644 §4", j.hasSchema(body, urn.service_provider_config), "ServiceProviderConfig lists its schema URN", null);
    inline for (.{ "patch", "bulk", "filter", "changePassword", "sort", "etag" }) |feature| {
        _ = s.check(.must, ref, j.boolean(j.path(body, feature ++ ".supported")) != null, feature ++ ".supported is a boolean", null);
    }
    s.caps = .{
        .patch = j.boolean(j.path(body, "patch.supported")) orelse true,
        .bulk = j.boolean(j.path(body, "bulk.supported")) orelse true,
        .filter = j.boolean(j.path(body, "filter.supported")) orelse true,
        .sort = j.boolean(j.path(body, "sort.supported")) orelse true,
        .etag = j.boolean(j.path(body, "etag.supported")) orelse true,
        .max_results = j.integer(j.path(body, "filter.maxResults")),
        .bulk_max_operations = j.integer(j.path(body, "bulk.maxOperations")),
        .bulk_max_payload_size = j.integer(j.path(body, "bulk.maxPayloadSize")),
    };
    // RFC 7643 §5: these are REQUIRED whether or not the feature is supported.
    _ = s.check(.must, ref, s.caps.max_results != null, "filter.maxResults is an integer", null);
    _ = s.check(.must, ref, s.caps.bulk_max_operations != null and s.caps.bulk_max_payload_size != null, "bulk.maxOperations and bulk.maxPayloadSize are integers", null);
    const schemes = j.array(j.field(body, "authenticationSchemes"));
    _ = s.check(.must, ref, schemes != null, "authenticationSchemes is an array", null);
    var complete = true;
    for (schemes orelse &.{}) |scheme| {
        complete = complete and j.string(j.field(scheme, "type")) != null and j.string(j.field(scheme, "name")) != null and j.string(j.field(scheme, "description")) != null;
    }
    _ = s.check(.must, ref, complete, "each authentication scheme has type, name and description", null);
    const scheme_types = [_][]const u8{ "oauth", "oauth2", "oauthbearertoken", "httpbasic", "httpdigest" };
    var unknown_scheme: ?[]const u8 = null;
    for (schemes orelse &.{}) |scheme| {
        const t = j.string(j.field(scheme, "type")) orelse continue;
        if (!oneOf(&scheme_types, t)) unknown_scheme = unknown_scheme orelse t;
    }
    _ = s.check(.should, ref, unknown_scheme == null, "each authentication scheme type is one the RFC defines", unknown_scheme);
    if (res.content_location) |loc| {
        _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(body, "meta.location")), loc), "meta.location equals the Content-Location header", null);
    }
    s.print("      features: patch={} bulk={} filter={} sort={} etag={} maxResults={?d}\n", .{
        s.caps.patch, s.caps.bulk, s.caps.filter, s.caps.sort, s.caps.etag, s.caps.max_results,
    });
}

fn resourceTypes(s: *Suite) []const Value {
    const ref = "RFC7643 §6";
    const res = s.send(.GET, "/ResourceTypes", .{}) orelse return &.{};
    const body = s.expectList("RFC7644 §4", res, "GET /ResourceTypes returns a ListResponse") orelse return &.{};
    const resources = j.array(j.field(body, "Resources")) orelse &.{};
    var ok = true;
    var extensions_ok = true;
    var not_relative: ?[]const u8 = null;
    var has_group = false;
    for (resources) |rt| {
        const name = j.string(j.field(rt, "name")) orelse "";
        const endpoint = j.string(j.field(rt, "endpoint"));
        ok = ok and j.hasSchema(rt, urn.resource_type) and name.len > 0 and endpoint != null and j.string(j.field(rt, "schema")) != null;
        for (j.array(j.field(rt, "schemaExtensions")) orelse &.{}) |ext| {
            extensions_ok = extensions_ok and j.string(j.field(ext, "schema")) != null and j.boolean(j.field(ext, "required")) != null;
        }
        const e = endpoint orelse continue;
        if (Client.isAbsolute(e) or s.client.isUnderBasePath(e)) not_relative = not_relative orelse e;
        if (std.mem.eql(u8, name, "User")) {
            s.users_endpoint = e;
            s.enterprise_user = j.findBy(j.array(j.field(rt, "schemaExtensions")), "schema", urn.enterprise_user) != null;
        }
        if (std.mem.eql(u8, name, "Group")) {
            s.groups_endpoint = e;
            has_group = true;
        }
    }
    _ = s.check(.must, ref, ok and resources.len > 0, "each ResourceType has schemas, name, endpoint and schema", null);
    _ = s.check(.must, ref, extensions_ok, "each schemaExtension has schema and a boolean required", null);
    _ = s.check(.must, ref, not_relative == null, "each ResourceType endpoint is relative to the base URL", if (not_relative) |e| s.fmt("got endpoint {s}", .{e}) else null);
    if (!has_group) s.groups_endpoint = null;
    s.print("      endpoints: users={s} groups={s} enterprise extension={}\n", .{ s.users_endpoint, s.groups_endpoint orelse "(none)", s.enterprise_user });
    return resources;
}

fn schemaList(s: *Suite) []const Value {
    const res = s.send(.GET, "/Schemas", .{}) orelse return &.{};
    const body = s.expectList("RFC7644 §4", res, "GET /Schemas returns a ListResponse") orelse return &.{};
    const resources = j.array(j.field(body, "Resources")) orelse &.{};
    for (resources) |schema| {
        const id = j.string(j.field(schema, "id")) orelse "(no id)";
        const attributes = j.array(j.field(schema, "attributes"));
        if (!s.check(.must, "RFC7643 §7", j.string(j.field(schema, "id")) != null and attributes != null, s.fmt("schema {s} has an id and attributes", .{id}), null)) continue;
        const problem = attributeProblem(s, attributes.?, "");
        _ = s.check(.must, "RFC7643 §7", problem == null, s.fmt("schema {s} attribute definitions are well formed", .{id}), problem);
    }
    return resources;
}

/// Validates attribute definitions (RFC 7643 §7, defaults in §2.2).
/// Returns a description of the first problem found.
fn attributeProblem(s: *Suite, attributes: []const Value, parent: []const u8) ?[]const u8 {
    const types = [_][]const u8{ "string", "boolean", "decimal", "integer", "dateTime", "reference", "binary", "complex" };
    const mutability = [_][]const u8{ "readOnly", "readWrite", "immutable", "writeOnly" };
    const returned = [_][]const u8{ "always", "never", "default", "request" };
    const uniqueness = [_][]const u8{ "none", "server", "global" };
    for (attributes) |attr| {
        const name = j.string(j.field(attr, "name")) orelse return s.fmt("{s}: attribute without a name", .{parent});
        const qualified = if (parent.len > 0) s.fmt("{s}.{s}", .{ parent, name }) else name;
        const t = j.string(j.field(attr, "type")) orelse return s.fmt("{s}: missing type", .{qualified});
        if (!oneOf(&types, t)) return s.fmt("{s}: type \"{s}\" is not a SCIM type", .{ qualified, t });
        inline for (.{ "multiValued", "required", "caseExact" }) |flag| {
            if (j.field(attr, flag)) |v| if (v != .bool) return s.fmt("{s}: {s} is not a boolean", .{ qualified, flag });
        }
        inline for (.{ .{ "mutability", &mutability }, .{ "returned", &returned }, .{ "uniqueness", &uniqueness } }) |c| {
            if (j.field(attr, c[0])) |v| {
                const str = j.string(v) orelse return s.fmt("{s}: {s} is not a string", .{ qualified, c[0] });
                if (!oneOf(c[1], str)) return s.fmt("{s}: {s} \"{s}\" is not allowed", .{ qualified, c[0], str });
            }
        }
        if (std.mem.eql(u8, t, "complex")) {
            const subs = j.array(j.field(attr, "subAttributes")) orelse return s.fmt("{s}: complex attribute without subAttributes", .{qualified});
            if (parent.len > 0) return s.fmt("{s}: complex attributes cannot nest (RFC 7643 §2.3.8)", .{qualified});
            if (attributeProblem(s, subs, qualified)) |p| return p;
        } else if (j.array(j.field(attr, "subAttributes")) != null) {
            // RFC 7643 §1.2: a simple attribute MUST NOT contain sub-attributes.
            return s.fmt("{s}: type \"{s}\" is not complex but has subAttributes (RFC 7643 §1.2)", .{ qualified, t });
        }
        if (std.mem.eql(u8, t, "reference") and j.array(j.field(attr, "referenceTypes")) == null) {
            return s.fmt("{s}: reference attribute without referenceTypes", .{qualified});
        }
    }
    return null;
}

fn oneOf(set: []const []const u8, v: []const u8) bool {
    for (set) |item| if (std.mem.eql(u8, item, v)) return true;
    return false;
}

fn crossReference(s: *Suite, types: []const Value, schemas: []const Value) void {
    if (types.len == 0 or schemas.len == 0) return;
    var missing: ?[]const u8 = null;
    for (types) |rt| {
        if (j.string(j.field(rt, "schema"))) |id| {
            if (j.findBy(schemas, "id", id) == null) missing = id;
        }
        for (j.array(j.field(rt, "schemaExtensions")) orelse &.{}) |ext| {
            if (j.string(j.field(ext, "schema"))) |id| if (j.findBy(schemas, "id", id) == null) {
                missing = id;
            };
        }
    }
    _ = s.check(.must, "RFC7643 §6", missing == null, "every ResourceType schema and extension is published in /Schemas", missing);

    // The core User schema as defined in RFC 7643 §4.1 / §8.7.1.
    if (j.findBy(schemas, "id", urn.user)) |user| {
        s.user_schema = user;
        const attrs = j.array(j.field(user, "attributes"));
        const user_name = j.findBy(attrs, "name", "userName");
        _ = s.check(.should, "RFC7643 §8.7.1", j.boolean(j.field(user_name, "required")) == true and eql(j.string(j.field(user_name, "uniqueness")), "server"), "User.userName is required with server uniqueness", null);
        const password = j.findBy(attrs, "name", "password");
        if (password != null) {
            _ = s.check(.must, "RFC7643 §4.1.1", eql(j.string(j.field(password, "returned")), "never") and eql(j.string(j.field(password, "mutability")), "writeOnly"), "User.password is writeOnly and never returned", null);
        }
        const groups = j.findBy(attrs, "name", "groups");
        if (groups != null) {
            _ = s.check(.should, "RFC7643 §4.1.2", eql(j.string(j.field(groups, "mutability")), "readOnly"), "User.groups is readOnly", null);
        }
    }
    if (j.findBy(schemas, "id", urn.group)) |group| {
        const display = j.findBy(j.array(j.field(group, "attributes")), "name", "displayName");
        _ = s.check(.should, "RFC7643 §8.7.1", j.boolean(j.field(display, "required")) == true, "Group.displayName is required", null);
    }
}

fn individualEndpoints(s: *Suite, types: []const Value, schemas: []const Value) void {
    const ref = "RFC7644 §4";
    for (types) |rt| {
        const name = j.string(j.field(rt, "name")) orelse continue;
        const id = j.string(j.field(rt, "id")) orelse name;
        const res = s.send(.GET, s.fmt("/ResourceTypes/{s}", .{id}), .{}) orelse continue;
        if (s.expectStatus(.should, ref, res, .ok, s.fmt("GET /ResourceTypes/{s} returns 200", .{id}))) {
            _ = s.check(.should, ref, eql(j.string(j.field(s.json(res), "name")), name), s.fmt("  /ResourceTypes/{s} is the {s} resource type", .{ id, name }), null);
        }
    }
    for (schemas) |schema| {
        const id = j.string(j.field(schema, "id")) orelse continue;
        const res = s.send(.GET, s.fmt("/Schemas/{s}", .{id}), .{}) orelse continue;
        if (s.expectStatus(.should, ref, res, .ok, s.fmt("GET /Schemas/{s} returns 200", .{id}))) {
            _ = s.check(.should, ref, eql(j.string(j.field(s.json(res), "id")), id), "  schema id matches the requested URN", null);
        }
    }
    if (s.send(.GET, "/ResourceTypes/ScimcheckUnknown", .{})) |res| {
        s.expectError(.should, ref, res, .not_found, null, "GET an unknown ResourceType returns 404");
    }
    if (s.send(.GET, "/Schemas/urn:scimcheck:unknown", .{})) |res| {
        s.expectError(.should, ref, res, .not_found, null, "GET an unknown Schema returns 404");
    }
}
