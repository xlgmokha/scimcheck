//! Conformance checks for SCIM 2.0 service providers.
//!
//! Each check cites the RFC 7643 / RFC 7644 section it verifies and has a
//! level: a violated MUST fails the run, a violated SHOULD is a warning.
//! Optional features (PATCH, filtering, sorting, ETags, bulk) are skipped when
//! the service provider's `/ServiceProviderConfig` says they are unsupported.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Client = @import("Client.zig");
const j = @import("json.zig");

pub const urn = struct {
    pub const user = "urn:ietf:params:scim:schemas:core:2.0:User";
    pub const group = "urn:ietf:params:scim:schemas:core:2.0:Group";
    pub const enterprise_user = "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User";
    pub const service_provider_config = "urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig";
    pub const resource_type = "urn:ietf:params:scim:schemas:core:2.0:ResourceType";
    pub const schema = "urn:ietf:params:scim:schemas:core:2.0:Schema";
    pub const list_response = "urn:ietf:params:scim:api:messages:2.0:ListResponse";
    pub const search_request = "urn:ietf:params:scim:api:messages:2.0:SearchRequest";
    pub const patch_op = "urn:ietf:params:scim:api:messages:2.0:PatchOp";
    pub const bulk_request = "urn:ietf:params:scim:api:messages:2.0:BulkRequest";
    pub const bulk_response = "urn:ietf:params:scim:api:messages:2.0:BulkResponse";
    pub const @"error" = "urn:ietf:params:scim:api:messages:2.0:Error";
};

pub const Level = enum { must, should };

pub const Section = enum {
    discovery,
    auth,
    errors,
    users,
    attributes,
    filter,
    pagination,
    sort,
    patch,
    etag,
    groups,
    bulk,

    pub fn title(s: Section) []const u8 {
        return switch (s) {
            .discovery => "Discovery (RFC 7644 §4)",
            .auth => "Authentication (RFC 7644 §2)",
            .errors => "Errors (RFC 7644 §3.12)",
            .users => "Users CRUD (RFC 7644 §3.3-3.6)",
            .attributes => "Attribute selection (RFC 7644 §3.9)",
            .filter => "Filtering (RFC 7644 §3.4.2.2)",
            .pagination => "Pagination (RFC 7644 §3.4.2.4)",
            .sort => "Sorting (RFC 7644 §3.4.2.3)",
            .patch => "PATCH (RFC 7644 §3.5.2)",
            .etag => "Versioning (RFC 7644 §3.14)",
            .groups => "Groups (RFC 7643 §4.2)",
            .bulk => "Bulk (RFC 7644 §3.7)",
        };
    }
};

pub const Options = struct {
    /// Run only these sections. Empty runs everything.
    only: std.EnumSet(Section) = .initFull(),
    /// Leave the resources created by the run on the server.
    keep: bool = false,
};

pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    warned: usize = 0,
    skipped: usize = 0,
};

/// Features advertised in `/ServiceProviderConfig` (RFC 7643 §5). Unknown
/// features are assumed supported so their checks still run.
const Capabilities = struct {
    patch: bool = true,
    bulk: bool = true,
    filter: bool = true,
    sort: bool = true,
    etag: bool = true,
};

const Fixture = struct {
    id: []const u8,
    user_name: []const u8,
    path: []const u8,
};

pub const Suite = struct {
    arena: Allocator,
    io: Io,
    client: *Client,
    out: *Io.Writer,
    options: Options,
    summary: Summary = .{},
    caps: Capabilities = .{},
    users_endpoint: []const u8 = "/Users",
    groups_endpoint: ?[]const u8 = "/Groups",
    run_id: []const u8 = "",
    /// Resources created by the run, deleted at the end unless `keep` is set.
    created: std.ArrayList([]const u8) = .empty,
    fixtures: ?[3]Fixture = null,

    pub fn init(arena: Allocator, io: Io, client: *Client, out: *Io.Writer, options: Options) Suite {
        var bytes: [4]u8 = undefined;
        io.random(&bytes);
        return .{
            .arena = arena,
            .io = io,
            .client = client,
            .out = out,
            .options = options,
            .run_id = std.fmt.allocPrint(arena, "{x}", .{bytes}) catch "run",
        };
    }

    pub fn run(s: *Suite) Summary {
        s.print("scimcheck {s} (run {s})\n", .{ s.client.base_url, s.run_id });

        // Discovery always runs: it tells us which endpoints and features exist.
        s.section(.discovery);
        s.discovery();

        const sections = [_]struct { Section, *const fn (*Suite) void }{
            .{ .auth, auth },
            .{ .errors, errors },
            .{ .users, users },
            .{ .attributes, attributes },
            .{ .filter, filter },
            .{ .pagination, pagination },
            .{ .sort, sort },
            .{ .patch, patch },
            .{ .etag, etag },
            .{ .groups, groups },
            .{ .bulk, bulk },
        };
        for (sections) |entry| {
            if (!s.options.only.contains(entry[0])) continue;
            s.section(entry[0]);
            entry[1](s);
        }

        s.cleanup();
        s.print("\n{d} passed, {d} failed, {d} warnings, {d} skipped\n", .{
            s.summary.passed, s.summary.failed, s.summary.warned, s.summary.skipped,
        });
        s.out.flush() catch {};
        return s.summary;
    }

    // ------------------------------------------------------------------
    // Sections
    // ------------------------------------------------------------------

    fn discovery(s: *Suite) void {
        const ref = "RFC7644 §4";
        if (s.send(.GET, "/ServiceProviderConfig", .{})) |res| {
            if (s.expectStatus(.must, ref, res, .ok, "GET /ServiceProviderConfig returns 200")) {
                s.expectMediaType(res);
                const body = res.json(s.arena);
                _ = s.check(.must, "RFC7643 §5", j.hasSchema(body, urn.service_provider_config), "ServiceProviderConfig lists its schema URN", null);
                inline for (.{ "patch", "bulk", "filter", "changePassword", "sort", "etag" }) |feature| {
                    const supported = j.boolean(j.path(body, feature ++ ".supported"));
                    _ = s.check(.must, "RFC7643 §5", supported != null, feature ++ ".supported is a boolean", null);
                }
                _ = s.check(.must, "RFC7643 §5", j.array(j.field(body, "authenticationSchemes")) != null, "authenticationSchemes is an array", null);
                s.caps = .{
                    .patch = j.boolean(j.path(body, "patch.supported")) orelse true,
                    .bulk = j.boolean(j.path(body, "bulk.supported")) orelse true,
                    .filter = j.boolean(j.path(body, "filter.supported")) orelse true,
                    .sort = j.boolean(j.path(body, "sort.supported")) orelse true,
                    .etag = j.boolean(j.path(body, "etag.supported")) orelse true,
                };
                s.print("      features: patch={} bulk={} filter={} sort={} etag={}\n", .{
                    s.caps.patch, s.caps.bulk, s.caps.filter, s.caps.sort, s.caps.etag,
                });
            }
        }

        if (s.send(.GET, "/ResourceTypes", .{})) |res| {
            if (s.expectList(ref, res, "GET /ResourceTypes returns a ListResponse")) |body| {
                const resources = j.array(j.field(body, "Resources")) orelse &.{};
                var ok = true;
                var has_group = false;
                for (resources) |rt| {
                    const name = j.string(j.field(rt, "name")) orelse "";
                    const endpoint = j.string(j.field(rt, "endpoint"));
                    ok = ok and j.hasSchema(rt, urn.resource_type) and name.len > 0 and endpoint != null and j.string(j.field(rt, "schema")) != null;
                    if (endpoint) |e| {
                        if (std.mem.eql(u8, name, "User")) s.users_endpoint = e;
                        if (std.mem.eql(u8, name, "Group")) {
                            s.groups_endpoint = e;
                            has_group = true;
                        }
                    }
                }
                _ = s.check(.must, "RFC7643 §6", ok and resources.len > 0, "each ResourceType has schemas, name, endpoint and schema", null);
                if (!has_group) s.groups_endpoint = null;
                s.print("      endpoints: users={s} groups={s}\n", .{ s.users_endpoint, s.groups_endpoint orelse "(none)" });
            }
        }

        if (s.send(.GET, "/ResourceTypes/User", .{})) |res| {
            if (s.expectStatus(.should, ref, res, .ok, "GET /ResourceTypes/User returns 200")) {
                _ = s.check(.should, ref, std.mem.eql(u8, j.string(j.field(res.json(s.arena), "name")) orelse "", "User"), "ResourceType User is named User", null);
            }
        }

        if (s.send(.GET, "/Schemas", .{})) |res| {
            if (s.expectList(ref, res, "GET /Schemas returns a ListResponse")) |body| {
                const resources = j.array(j.field(body, "Resources")) orelse &.{};
                var ok = true;
                for (resources) |sch| ok = ok and j.string(j.field(sch, "id")) != null and j.array(j.field(sch, "attributes")) != null;
                _ = s.check(.must, "RFC7643 §7", ok and resources.len > 0, "each Schema has an id and attributes", null);
                _ = s.check(.must, "RFC7643 §7", j.findBy(resources, "id", urn.user) != null, "Schemas includes the core User schema", null);
            }
        }

        if (s.send(.GET, "/Schemas/" ++ urn.user, .{})) |res| {
            if (s.expectStatus(.should, ref, res, .ok, "GET /Schemas/{urn} returns the User schema")) {
                _ = s.check(.should, ref, std.mem.eql(u8, j.string(j.field(res.json(s.arena), "id")) orelse "", urn.user), "schema id matches the requested URN", null);
            }
        }

        if (s.send(.GET, "/ResourceTypes?filter=name%20eq%20%22User%22", .{})) |res| {
            _ = s.expectStatus(.should, ref, res, .forbidden, "filtering /ResourceTypes returns 403");
        }
    }

    fn auth(s: *Suite) void {
        const ref = "RFC7644 §2";
        if (s.client.authorization == null) return s.skip("no credentials configured (--token)");
        const res = s.send(.GET, s.users_endpoint, .{ .authenticate = false }) orelse return;
        if (s.expectStatus(.must, ref, res, .unauthorized, "unauthenticated request returns 401")) {
            _ = s.check(.should, "RFC7235 §3.1", res.www_authenticate != null, "401 response includes WWW-Authenticate", null);
        }
    }

    fn errors(s: *Suite) void {
        const ref = "RFC7644 §3.12";
        if (s.send(.GET, s.fmt("{s}/scimcheck-{s}-missing", .{ s.users_endpoint, s.run_id }), .{})) |res| {
            s.expectError(.must, ref, res, .not_found, null, "GET unknown User returns 404 Error");
        }
        if (s.send(.GET, "/ScimcheckUnknownEndpoint", .{})) |res| {
            _ = s.expectStatus(.should, ref, res, .not_found, "GET unknown endpoint returns 404");
        }
        if (s.send(.POST, s.users_endpoint, .{ .body = "{\"schemas\": [" })) |res| {
            s.expectError(.must, ref, res, .bad_request, "invalidSyntax", "POST malformed JSON returns 400 invalidSyntax");
        }
        const missing = s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":\"no username\"}}", .{urn.user});
        if (s.send(.POST, s.users_endpoint, .{ .body = missing })) |res| {
            s.expectError(.must, "RFC7643 §4.1", res, .bad_request, "invalidValue", "POST User without userName returns 400 invalidValue");
            s.trackCreated(res);
        }
    }

    fn users(s: *Suite) void {
        const ref = "RFC7644 §3.3";
        const user_name = s.fmt("scimcheck-{s}-crud", .{s.run_id});
        const res = s.send(.POST, s.users_endpoint, .{ .body = s.userJson(user_name, "Barbara Jensen") }) orelse return;
        if (!s.expectStatus(.must, ref, res, .created, "POST /Users returns 201")) return;
        s.expectMediaType(res);
        const body = res.json(s.arena);
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
        _ = s.check(.must, "RFC7643 §3", j.hasSchema(body, urn.user), "created User lists the core User schema", null);
        _ = s.check(.must, "RFC7643 §4.1", eql(j.string(j.field(body, "userName")), user_name), "created User echoes userName", null);
        _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(body, "meta.resourceType")), "User"), "meta.resourceType is User", null);
        _ = s.check(.should, "RFC7643 §3.1", isDateTime(j.string(j.path(body, "meta.created"))), "meta.created is a dateTime", null);
        _ = s.check(.should, "RFC7643 §3.1", isDateTime(j.string(j.path(body, "meta.lastModified"))), "meta.lastModified is a dateTime", null);
        _ = s.check(.must, "RFC7643 §4.1.1", j.field(body, "password") == null, "password is never returned", null);
        if (s.caps.etag) {
            _ = s.check(.must, "RFC7644 §3.14", res.etag != null, "201 response includes an ETag header", null);
            if (res.etag) |e| _ = s.check(.should, "RFC7644 §3.14", eql(j.string(j.path(body, "meta.version")), e), "meta.version equals the ETag header", null);
        }

        if (s.send(.POST, s.users_endpoint, .{ .body = s.userJson(user_name, "Duplicate") })) |dup| {
            s.expectError(.must, ref, dup, .conflict, "uniqueness", "POST duplicate userName returns 409 uniqueness");
            s.trackCreated(dup);
        }
        const upper = std.ascii.allocUpperString(s.arena, user_name) catch user_name;
        if (s.send(.POST, s.users_endpoint, .{ .body = s.userJson(upper, "Duplicate") })) |dup| {
            _ = s.expectStatus(.should, "RFC7643 §4.1", dup, .conflict, "userName uniqueness is case-insensitive");
            s.trackCreated(dup);
        }

        if (s.send(.GET, path, .{})) |got| {
            if (s.expectStatus(.must, "RFC7644 §3.4.1", got, .ok, "GET /Users/{id} returns 200")) {
                s.expectMediaType(got);
                const g = got.json(s.arena);
                _ = s.check(.must, "RFC7644 §3.4.1", eql(j.string(j.field(g, "id")), id), "retrieved User has the same id", null);
                _ = s.check(.must, "RFC7643 §4.1.1", j.field(g, "password") == null, "password is never returned", null);
            }
        }

        if (s.send(.PUT, path, .{ .body = s.userJson(user_name, "Babs Jensen") })) |put| {
            if (s.expectStatus(.must, "RFC7644 §3.5.1", put, .ok, "PUT /Users/{id} returns 200")) {
                const p = put.json(s.arena);
                _ = s.check(.must, "RFC7644 §3.5.1", eql(j.string(j.field(p, "displayName")), "Babs Jensen"), "PUT replaces displayName", null);
                _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.field(p, "id")), id), "PUT keeps the id", null);
                if (s.caps.etag and res.etag != null and put.etag != null) {
                    _ = s.check(.should, "RFC7644 §3.14", !std.mem.eql(u8, res.etag.?, put.etag.?), "ETag changes after PUT", null);
                }
            }
        }

        if (s.send(.DELETE, path, .{})) |del| {
            if (s.expectStatus(.must, "RFC7644 §3.6", del, .no_content, "DELETE /Users/{id} returns 204")) s.untrack(path);
        }
        if (s.send(.GET, path, .{})) |gone| {
            s.expectError(.must, "RFC7644 §3.6", gone, .not_found, null, "GET deleted User returns 404");
        }
        if (s.send(.DELETE, path, .{})) |again| {
            _ = s.expectStatus(.should, "RFC7644 §3.6", again, .not_found, "DELETE deleted User returns 404");
        }
    }

    fn attributes(s: *Suite) void {
        const ref = "RFC7644 §3.9";
        const f = s.requireFixtures() orelse return;
        if (s.send(.GET, s.fmt("{s}?attributes=userName", .{f[0].path}), .{})) |res| {
            if (s.expectStatus(.must, ref, res, .ok, "GET with attributes=userName returns 200")) {
                const body = res.json(s.arena);
                _ = s.check(.must, ref, j.field(body, "userName") != null, "attributes=userName returns userName", null);
                _ = s.check(.must, "RFC7643 §7", j.field(body, "id") != null, "attributes= still returns id (returned: always)", null);
                _ = s.check(.must, ref, j.field(body, "displayName") == null and j.field(body, "emails") == null, "attributes=userName omits other attributes", res.body);
            }
        }
        if (s.send(.GET, s.fmt("{s}?attributes=name.givenName", .{f[0].path}), .{})) |res| {
            if (s.expectStatus(.must, ref, res, .ok, "GET with attributes=name.givenName returns 200")) {
                const body = res.json(s.arena);
                _ = s.check(.must, ref, j.path(body, "name.givenName") != null and j.path(body, "name.familyName") == null, "sub-attribute selection omits sibling sub-attributes", res.body);
            }
        }
        if (s.send(.GET, s.fmt("{s}?excludedAttributes=emails", .{f[0].path}), .{})) |res| {
            if (s.expectStatus(.must, ref, res, .ok, "GET with excludedAttributes=emails returns 200")) {
                const body = res.json(s.arena);
                _ = s.check(.must, ref, j.field(body, "emails") == null, "excludedAttributes=emails omits emails", res.body);
                _ = s.check(.must, ref, j.field(body, "userName") != null and j.field(body, "id") != null, "excludedAttributes keeps other attributes", null);
            }
        }
        if (s.send(.GET, s.fmt("{s}?excludedAttributes=id", .{f[0].path}), .{})) |res| {
            if (s.expectStatus(.must, ref, res, .ok, "GET with excludedAttributes=id returns 200")) {
                _ = s.check(.must, "RFC7643 §7", j.field(res.json(s.arena), "id") != null, "excludedAttributes cannot remove id (returned: always)", null);
            }
        }
        const list = s.fmt("{s}?filter={s}&attributes=displayName", .{ s.users_endpoint, s.escape(s.fmt("userName eq \"{s}\"", .{f[0].user_name})) });
        if (!s.caps.filter) return;
        if (s.send(.GET, list, .{})) |res| {
            if (s.expectList(ref, res, "list with attributes=displayName returns a ListResponse")) |body| {
                const first = if (j.array(j.field(body, "Resources"))) |r| (if (r.len > 0) r[0] else null) else null;
                _ = s.check(.must, ref, first != null and j.field(first, "displayName") != null and j.field(first, "emails") == null, "attributes applies to each listed resource", res.body);
            }
        }
    }

    fn filter(s: *Suite) void {
        const ref = "RFC7644 §3.4.2.2";
        if (!s.caps.filter) return s.skip("filter.supported is false");
        const f = s.requireFixtures() orelse return;
        const prefix = s.fixturePrefix();

        s.expectCount(ref, .must, s.fmt("userName eq \"{s}\"", .{f[0].user_name}), 1, "eq matches exactly one User");
        s.expectCount(ref, .must, s.fmt("userName eq \"{s}\"", .{std.ascii.allocUpperString(s.arena, f[0].user_name) catch ""}), 1, "eq on userName is case-insensitive (caseExact false)");
        s.expectCount("RFC7643 §2.1", .should, s.fmt("USERNAME eq \"{s}\"", .{f[0].user_name}), 1, "attribute names in filters are case-insensitive");
        s.expectCount(ref, .must, s.fmt("userName sw \"{s}\"", .{prefix}), 3, "sw matches the three fixtures");
        s.expectCount(ref, .must, s.fmt("userName co \"{s}\" and userName ew \"-bob\"", .{prefix}), 1, "and/co/ew combine");
        s.expectCount(ref, .must, s.fmt("userName eq \"{s}\" or userName eq \"{s}\"", .{ f[0].user_name, f[1].user_name }), 2, "or matches either side");
        s.expectCount(ref, .must, s.fmt("userName sw \"{s}\" and not (userName eq \"{s}\")", .{ prefix, f[0].user_name }), 2, "not negates a grouped expression");
        s.expectCount(ref, .must, s.fmt("userName sw \"{s}\" and emails pr", .{prefix}), 3, "pr matches present attributes");
        s.expectCount(ref, .must, s.fmt("userName sw \"{s}\" and emails[type eq \"work\" and value co \"@example.com\"]", .{prefix}), 3, "complex attribute filter on emails");
        s.expectCount(ref, .must, s.fmt("userName sw \"{s}\" and emails.type eq \"work\"", .{prefix}), 3, "sub-attribute path emails.type");
        s.expectCount(ref, .must, s.fmt("userName sw \"{s}\" and meta.created gt \"2000-01-01T00:00:00Z\"", .{prefix}), 3, "gt on a dateTime");
        s.expectCount(ref, .must, s.fmt("userName eq \"{s}-nobody\"", .{prefix}), 0, "no match returns 200 with totalResults 0");

        if (s.send(.GET, s.fmt("{s}?filter={s}", .{ s.users_endpoint, s.escape("userName eq") }), .{})) |res| {
            s.expectError(.must, ref, res, .bad_request, "invalidFilter", "malformed filter returns 400 invalidFilter");
        }

        const search = s.fmt(
            \\{{"schemas":["{s}"],"filter":{f},"startIndex":1,"count":10}}
        , .{ urn.search_request, std.json.fmt(s.fmt("userName eq \"{s}\"", .{f[1].user_name}), .{}) });
        if (s.send(.POST, s.fmt("{s}/.search", .{s.users_endpoint}), .{ .body = search })) |res| {
            // Clients MAY search with POST, so support is a SHOULD rather than a MUST.
            if (!s.expectStatus(.should, "RFC7644 §3.4.3", res, .ok, "POST /Users/.search returns 200")) return;
            if (s.expectList("RFC7644 §3.4.3", res, "POST /Users/.search returns a ListResponse")) |body| {
                _ = s.check(.must, "RFC7644 §3.4.3", j.integer(j.field(body, "totalResults")) == 1, "POST /.search applies the filter", res.body);
            }
        }
    }

    fn pagination(s: *Suite) void {
        const ref = "RFC7644 §3.4.2.4";
        if (!s.caps.filter) return s.skip("filter.supported is false");
        _ = s.requireFixtures() orelse return;
        const base = s.fmt("{s}?filter={s}", .{ s.users_endpoint, s.escape(s.fmt("userName sw \"{s}\"", .{s.fixturePrefix()})) });

        if (s.send(.GET, s.fmt("{s}&count=1", .{base}), .{})) |res| {
            if (s.expectList(ref, res, "count=1 returns a ListResponse")) |body| {
                _ = s.check(.must, ref, j.integer(j.field(body, "totalResults")) == 3, "totalResults counts every match, not the page", res.body);
                _ = s.check(.must, ref, resourceCount(body) == 1, "count=1 returns one resource", null);
                _ = s.check(.must, ref, j.integer(j.field(body, "itemsPerPage")) == 1, "itemsPerPage equals the page size", null);
                _ = s.check(.must, ref, j.integer(j.field(body, "startIndex")) == 1, "startIndex defaults to 1", null);
            }
        }
        if (s.send(.GET, s.fmt("{s}&startIndex=3&count=2", .{base}), .{})) |res| {
            if (s.expectList(ref, res, "startIndex=3 returns a ListResponse")) |body| {
                _ = s.check(.must, ref, j.integer(j.field(body, "startIndex")) == 3, "startIndex is echoed", res.body);
                _ = s.check(.must, ref, resourceCount(body) == 1, "the last page holds the remaining resource", null);
            }
        }
        if (s.send(.GET, s.fmt("{s}&count=0", .{base}), .{})) |res| {
            if (s.expectList(ref, res, "count=0 returns a ListResponse")) |body| {
                _ = s.check(.must, ref, resourceCount(body) == 0, "count=0 returns no resources", res.body);
                _ = s.check(.must, ref, j.integer(j.field(body, "totalResults")) == 3, "count=0 still reports totalResults", null);
            }
        }
        if (s.send(.GET, s.fmt("{s}&startIndex=0", .{base}), .{})) |res| {
            if (s.expectList(ref, res, "startIndex=0 returns a ListResponse")) |body| {
                _ = s.check(.must, ref, j.integer(j.field(body, "startIndex")) == 1, "startIndex < 1 is interpreted as 1", res.body);
            }
        }
        if (s.send(.GET, s.fmt("{s}&count=-1", .{base}), .{})) |res| {
            if (s.expectList(ref, res, "count=-1 returns a ListResponse")) |body| {
                _ = s.check(.must, ref, resourceCount(body) == 0, "negative count is interpreted as 0", res.body);
            }
        }
    }

    fn sort(s: *Suite) void {
        const ref = "RFC7644 §3.4.2.3";
        if (!s.caps.sort) return s.skip("sort.supported is false");
        if (!s.caps.filter) return s.skip("filter.supported is false");
        const f = s.requireFixtures() orelse return;
        const base = s.fmt("{s}?filter={s}&sortBy=userName", .{ s.users_endpoint, s.escape(s.fmt("userName sw \"{s}\"", .{s.fixturePrefix()})) });
        const cases = [_]struct { []const u8, [3]usize, []const u8 }{
            .{ "", .{ 0, 1, 2 }, "sortBy=userName defaults to ascending" },
            .{ "&sortOrder=ascending", .{ 0, 1, 2 }, "sortOrder=ascending" },
            .{ "&sortOrder=descending", .{ 2, 1, 0 }, "sortOrder=descending" },
        };
        for (cases) |c| {
            const res = s.send(.GET, s.fmt("{s}{s}", .{ base, c[0] }), .{}) orelse continue;
            const body = s.expectList(ref, res, s.fmt("{s} returns a ListResponse", .{c[2]})) orelse continue;
            const resources = j.array(j.field(body, "Resources")) orelse &.{};
            var ok = resources.len == 3;
            if (ok) for (c[1], 0..) |fixture, i| {
                ok = ok and eql(j.string(j.field(resources[i], "userName")), f[fixture].user_name);
            };
            _ = s.check(.must, ref, ok, c[2], res.body);
        }
    }

    fn patch(s: *Suite) void {
        const ref = "RFC7644 §3.5.2";
        if (!s.caps.patch) return s.skip("patch.supported is false");
        const f = s.requireFixtures() orelse return;
        const path = f[2].path;

        s.expectPatch(ref, path,
            \\{"op":"replace","path":"displayName","value":"Patched Name"}
        , "replace with a path", "displayName", "Patched Name");
        s.expectPatch(ref, path,
            \\{"op":"replace","value":{"displayName":"Patched Again","nickName":"Babs"}}
        , "replace without a path", "nickName", "Babs");
        s.expectPatch(ref, path,
            \\{"op":"replace","path":"name.givenName","value":"Carla"}
        , "replace a sub-attribute", "name.givenName", "Carla");
        s.expectPatch(ref, path,
            \\{"op":"replace","path":"active","value":false}
        , "replace a boolean", null, null);
        if (s.send(.GET, path, .{})) |res| {
            _ = s.check(.must, ref, j.boolean(j.field(res.json(s.arena), "active")) == false, "replace a boolean: active is false", res.body);
        }

        s.expectPatch(ref, path,
            \\{"op":"add","path":"emails","value":[{"value":"carol@home.example.com","type":"home"}]}
        , "add to a multi-valued attribute", null, null);
        if (s.send(.GET, path, .{})) |res| {
            const emails = j.array(j.field(res.json(s.arena), "emails"));
            _ = s.check(.must, ref, j.findBy(emails, "type", "home") != null and j.findBy(emails, "type", "work") != null, "add appends to emails and keeps existing values", res.body);
        }

        s.expectPatch(ref, path,
            \\{"op":"replace","path":"emails[type eq \"home\"].value","value":"carol@elsewhere.example.com"}
        , "replace through a value filter", null, null);
        if (s.send(.GET, path, .{})) |res| {
            const home = j.findBy(j.array(j.field(res.json(s.arena), "emails")), "type", "home");
            _ = s.check(.must, ref, eql(j.string(j.field(home, "value")), "carol@elsewhere.example.com"), "replace through a value filter: value updated", res.body);
        }

        s.expectPatch(ref, path,
            \\{"op":"remove","path":"emails[type eq \"home\"]"}
        , "remove through a value filter", null, null);
        if (s.send(.GET, path, .{})) |res| {
            const emails = j.array(j.field(res.json(s.arena), "emails"));
            _ = s.check(.must, ref, j.findBy(emails, "type", "home") == null and j.findBy(emails, "type", "work") != null, "remove through a value filter: only the match is removed", res.body);
        }

        s.expectPatch(ref, path,
            \\{"op":"remove","path":"nickName"}
        , "remove an attribute", null, null);
        if (s.send(.GET, path, .{})) |res| {
            _ = s.check(.must, ref, j.field(res.json(s.arena), "nickName") == null, "remove an attribute: nickName is gone", res.body);
        }

        s.expectPatch(ref, path,
            \\{"op":"Replace","path":"displayName","value":"Case Insensitive Op"}
        , "op values are case-insensitive", "displayName", "Case Insensitive Op");

        if (s.send(.PATCH, path, .{ .body = patchJson(s, "{\"op\":\"remove\"}") })) |res| {
            s.expectError(.must, ref, res, .bad_request, "noTarget", "remove without a path returns 400 noTarget");
        }
        if (s.send(.PATCH, path, .{ .body = patchJson(s, "{\"op\":\"bogus\",\"path\":\"displayName\",\"value\":\"x\"}") })) |res| {
            s.expectError(.must, ref, res, .bad_request, null, "unknown op returns 400");
        }
        if (s.send(.PATCH, path, .{ .body = patchJson(s, "{\"op\":\"replace\",\"path\":\"emails[type eq]\",\"value\":\"x\"}") })) |res| {
            s.expectError(.must, ref, res, .bad_request, "invalidPath", "malformed path returns 400 invalidPath");
        }
        if (s.send(.PATCH, path, .{ .body = patchJson(s, "{\"op\":\"replace\",\"path\":\"id\",\"value\":\"new-id\"}") })) |res| {
            s.expectError(.should, "RFC7644 §3.5.2", res, .bad_request, "mutability", "replacing a readOnly attribute returns 400 mutability");
        }
        const no_schema = "{\"Operations\":[{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"x\"}]}";
        if (s.send(.PATCH, path, .{ .body = no_schema })) |res| {
            _ = s.expectStatus(.should, ref, res, .bad_request, "PatchOp without schemas returns 400");
        }
    }

    fn etag(s: *Suite) void {
        const ref = "RFC7644 §3.14";
        if (!s.caps.etag) return s.skip("etag.supported is false");
        const f = s.requireFixtures() orelse return;
        const fixture = f[1];
        const res = s.send(.GET, fixture.path, .{}) orelse return;
        if (!s.expectStatus(.must, ref, res, .ok, "GET fixture returns 200")) return;
        const tag = res.etag orelse {
            _ = s.check(.must, ref, false, "GET returns an ETag header", null);
            return;
        };
        _ = s.check(.must, ref, true, "GET returns an ETag header", null);
        _ = s.check(.should, ref, eql(j.string(j.path(res.json(s.arena), "meta.version")), tag), "meta.version equals the ETag header", null);

        if (s.send(.GET, fixture.path, .{ .if_none_match = tag })) |r| {
            _ = s.expectStatus(.should, ref, r, .not_modified, "If-None-Match with the current ETag returns 304");
        }
        const stale = "W/\"scimcheck-stale\"";
        const body = s.userJson(fixture.user_name, "Versioned");
        if (s.send(.PUT, fixture.path, .{ .body = body, .if_match = stale })) |r| {
            s.expectError(.must, ref, r, .precondition_failed, null, "PUT with a stale If-Match returns 412");
        }
        if (s.caps.patch) {
            if (s.send(.PATCH, fixture.path, .{ .body = patchJson(s, "{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"x\"}"), .if_match = stale })) |r| {
                s.expectError(.must, ref, r, .precondition_failed, null, "PATCH with a stale If-Match returns 412");
            }
        }
        if (s.send(.DELETE, fixture.path, .{ .if_match = stale })) |r| {
            s.expectError(.must, ref, r, .precondition_failed, null, "DELETE with a stale If-Match returns 412");
        }
        if (s.send(.PUT, fixture.path, .{ .body = body, .if_match = tag })) |r| {
            if (s.expectStatus(.must, ref, r, .ok, "PUT with the current If-Match returns 200")) {
                _ = s.check(.should, ref, r.etag != null and !std.mem.eql(u8, r.etag.?, tag), "ETag changes after an update", null);
            }
        }
    }

    fn groups(s: *Suite) void {
        const ref = "RFC7643 §4.2";
        const endpoint = s.groups_endpoint orelse return s.skip("no Group resource type");
        const f = s.requireFixtures() orelse return;
        const display = s.fmt("scimcheck-{s}-group", .{s.run_id});
        const payload = s.fmt(
            \\{{"schemas":["{s}"],"displayName":{f},"members":[{{"value":{f}}},{{"value":{f}}}]}}
        , .{ urn.group, std.json.fmt(display, .{}), std.json.fmt(f[0].id, .{}), std.json.fmt(f[1].id, .{}) });
        const res = s.send(.POST, endpoint, .{ .body = payload }) orelse return;
        if (!s.expectStatus(.must, "RFC7644 §3.3", res, .created, "POST /Groups returns 201")) return;
        const body = res.json(s.arena);
        const id = j.string(j.field(body, "id")) orelse {
            _ = s.check(.must, "RFC7643 §3.1", false, "created Group has an id", res.body);
            return;
        };
        const path = s.fmt("{s}/{s}", .{ endpoint, id });
        s.created.append(s.arena, path) catch {};
        _ = s.check(.must, "RFC7643 §3", j.hasSchema(body, urn.group), "created Group lists the core Group schema", null);
        _ = s.check(.must, "RFC7643 §3.1", eql(j.string(j.path(body, "meta.resourceType")), "Group"), "meta.resourceType is Group", null);
        _ = s.check(.must, ref, eql(j.string(j.field(body, "displayName")), display), "created Group echoes displayName", null);

        if (s.send(.GET, path, .{})) |got| {
            if (s.expectStatus(.must, "RFC7644 §3.4.1", got, .ok, "GET /Groups/{id} returns 200")) {
                const members = j.array(j.field(got.json(s.arena), "members"));
                _ = s.check(.must, ref, j.findBy(members, "value", f[0].id) != null and j.findBy(members, "value", f[1].id) != null, "Group lists both members", got.body);
            }
        }

        if (s.send(.GET, f[0].path, .{})) |got| {
            const member_of = j.array(j.field(got.json(s.arena), "groups"));
            _ = s.check(.should, "RFC7643 §4.1.2", j.findBy(member_of, "value", id) != null, "User.groups reflects Group membership", got.body);
        }

        if (s.caps.filter) {
            if (s.send(.GET, s.fmt("{s}?filter={s}", .{ endpoint, s.escape(s.fmt("displayName eq \"{s}\"", .{display})) }), .{})) |r| {
                if (s.expectList("RFC7644 §3.4.2.2", r, "filter Groups by displayName")) |b| {
                    _ = s.check(.must, "RFC7644 §3.4.2.2", j.integer(j.field(b, "totalResults")) == 1, "displayName filter matches the Group", r.body);
                }
            }
        }

        if (s.caps.patch) {
            const add = s.fmt("{{\"op\":\"add\",\"path\":\"members\",\"value\":[{{\"value\":{f}}}]}}", .{std.json.fmt(f[2].id, .{})});
            if (s.send(.PATCH, path, .{ .body = patchJson(s, add) })) |r| {
                if (s.expectPatchStatus("RFC7644 §3.5.2.1", r, "PATCH add member")) {
                    if (s.send(.GET, path, .{})) |got| {
                        const members = j.array(j.field(got.json(s.arena), "members"));
                        _ = s.check(.must, "RFC7644 §3.5.2.1", lenOf(members) == 3 and j.findBy(members, "value", f[2].id) != null, "PATCH add member keeps existing members", got.body);
                    }
                }
            }
            const remove = s.fmt("{{\"op\":\"remove\",\"path\":{f}}}", .{std.json.fmt(s.fmt("members[value eq \"{s}\"]", .{f[0].id}), .{})});
            if (s.send(.PATCH, path, .{ .body = patchJson(s, remove) })) |r| {
                if (s.expectPatchStatus("RFC7644 §3.5.2.2", r, "PATCH remove member")) {
                    if (s.send(.GET, path, .{})) |got| {
                        const members = j.array(j.field(got.json(s.arena), "members"));
                        _ = s.check(.must, "RFC7644 §3.5.2.2", lenOf(members) == 2 and j.findBy(members, "value", f[0].id) == null, "PATCH remove member removes only the match", got.body);
                    }
                }
            }
        }

        if (s.send(.DELETE, path, .{})) |del| {
            if (s.expectStatus(.must, "RFC7644 §3.6", del, .no_content, "DELETE /Groups/{id} returns 204")) s.untrack(path);
        }
    }

    fn bulk(s: *Suite) void {
        const ref = "RFC7644 §3.7";
        if (!s.caps.bulk) {
            const res = s.send(.POST, "/Bulk", .{ .body = s.fmt("{{\"schemas\":[\"{s}\"],\"Operations\":[]}}", .{urn.bulk_request}) }) orelse return;
            _ = s.expectStatus(.should, "RFC7644 §3.12", res, .not_implemented, "POST /Bulk returns 501 when bulk is unsupported");
            return;
        }
        const user_name = s.fmt("scimcheck-{s}-bulk", .{s.run_id});
        const payload = s.fmt(
            \\{{"schemas":["{s}"],"Operations":[{{"method":"POST","path":{f},"bulkId":"u1","data":{s}}}]}}
        , .{ urn.bulk_request, std.json.fmt(s.users_endpoint, .{}), s.userJson(user_name, "Bulk User") });
        const res = s.send(.POST, "/Bulk", .{ .body = payload }) orelse return;
        if (!s.expectStatus(.must, ref, res, .ok, "POST /Bulk returns 200")) return;
        const body = res.json(s.arena);
        _ = s.check(.must, ref, j.hasSchema(body, urn.bulk_response), "response lists the BulkResponse schema", null);
        const ops = j.array(j.field(body, "Operations")) orelse &.{};
        const op: ?Value = if (ops.len > 0) ops[0] else null;
        _ = s.check(.must, ref, eql(j.string(j.field(op, "status")), "201"), "bulk create reports status \"201\"", res.body);
        _ = s.check(.must, ref, eql(j.string(j.field(op, "bulkId")), "u1"), "bulk operation echoes bulkId", null);
        if (j.string(j.field(op, "location"))) |loc| {
            s.created.append(s.arena, loc) catch {};
        } else {
            _ = s.check(.must, ref, false, "bulk create returns a location", null);
        }
    }

    // ------------------------------------------------------------------
    // Fixtures and cleanup
    // ------------------------------------------------------------------

    fn fixturePrefix(s: *Suite) []const u8 {
        return s.fmt("scimcheck-{s}-f", .{s.run_id});
    }

    /// Creates three users (alice, bob, carol) shared by the query, PATCH,
    /// ETag and Group checks. They sort in that order by userName.
    fn requireFixtures(s: *Suite) ?[3]Fixture {
        if (s.fixtures) |f| return f;
        var result: [3]Fixture = undefined;
        for ([_][]const u8{ "alice", "bob", "carol" }, 0..) |who, i| {
            const user_name = s.fmt("{s}-{s}", .{ s.fixturePrefix(), who });
            const res = s.client.send(s.arena, .POST, s.users_endpoint, .{ .body = s.userJson(user_name, who) }) catch |err| {
                s.skip(s.fmt("could not create fixture {s}: {s}", .{ user_name, @errorName(err) }));
                return null;
            };
            const id = j.string(j.field(res.json(s.arena), "id"));
            if (res.status != .created or id == null) {
                s.skip(s.fmt("could not create fixture {s}: HTTP {d} {s}", .{ user_name, @intFromEnum(res.status), truncate(res.body) }));
                return null;
            }
            result[i] = .{ .id = id.?, .user_name = user_name, .path = s.fmt("{s}/{s}", .{ s.users_endpoint, id.? }) };
            s.created.append(s.arena, result[i].path) catch {};
        }
        s.fixtures = result;
        return result;
    }

    /// Tracks a resource a negative check created by mistake so cleanup removes it.
    fn trackCreated(s: *Suite, res: Client.Response) void {
        if (res.status != .created) return;
        const id = j.string(j.field(res.json(s.arena), "id")) orelse return;
        s.created.append(s.arena, s.fmt("{s}/{s}", .{ s.users_endpoint, id })) catch {};
    }

    fn untrack(s: *Suite, path: []const u8) void {
        for (s.created.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) {
            _ = s.created.orderedRemove(i);
            return;
        };
    }

    fn cleanup(s: *Suite) void {
        if (s.created.items.len == 0) return;
        if (s.options.keep) {
            s.print("\nKept {d} resources:\n", .{s.created.items.len});
            for (s.created.items) |p| s.print("  {s}\n", .{p});
            return;
        }
        // Delete in reverse so groups go before their members.
        var i = s.created.items.len;
        var failed: usize = 0;
        while (i > 0) {
            i -= 1;
            const p = s.created.items[i];
            const res = s.client.send(s.arena, .DELETE, p, .{}) catch {
                failed += 1;
                continue;
            };
            if (res.status != .no_content and res.status != .not_found) failed += 1;
        }
        if (failed > 0) s.print("\nwarning: could not delete {d} test resources\n", .{failed});
    }

    // ------------------------------------------------------------------
    // Assertions and reporting
    // ------------------------------------------------------------------

    fn section(s: *Suite, which: Section) void {
        s.print("\n{s}\n", .{which.title()});
    }

    fn print(s: *Suite, comptime format: []const u8, args: anytype) void {
        s.out.print(format, args) catch {};
    }

    fn fmt(s: *Suite, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(s.arena, format, args) catch "(out of memory)";
    }

    fn escape(s: *Suite, value: []const u8) []const u8 {
        return Client.queryEscape(s.arena, value) catch "";
    }

    fn skip(s: *Suite, why: []const u8) void {
        s.summary.skipped += 1;
        s.print("  SKIP  {s}\n", .{why});
    }

    /// Records one check. Returns `ok` so callers can gate follow-up checks.
    fn check(s: *Suite, level: Level, ref: []const u8, ok: bool, what: []const u8, detail: ?[]const u8) bool {
        const tag = if (ok) "PASS" else switch (level) {
            .must => "FAIL",
            .should => "WARN",
        };
        if (ok) {
            s.summary.passed += 1;
        } else switch (level) {
            .must => s.summary.failed += 1,
            .should => s.summary.warned += 1,
        }
        s.print("  {s}  {s} [{s}]\n", .{ tag, what, ref });
        if (!ok) if (detail) |d| s.print("        {s}\n", .{truncate(d)});
        s.out.flush() catch {};
        return ok;
    }

    fn send(s: *Suite, method: http.Method, target: []const u8, options: Client.Options) ?Client.Response {
        return s.client.send(s.arena, method, target, options) catch |err| {
            _ = s.check(.must, "transport", false, s.fmt("{s} {s}", .{ @tagName(method), target }), s.fmt("request failed: {s}", .{@errorName(err)}));
            return null;
        };
    }

    fn expectStatus(s: *Suite, level: Level, ref: []const u8, res: Client.Response, want: http.Status, what: []const u8) bool {
        return s.check(level, ref, res.status == want, what, s.fmt("got HTTP {d}: {s}", .{ @intFromEnum(res.status), res.body }));
    }

    fn expectMediaType(s: *Suite, res: Client.Response) void {
        _ = s.check(.must, "RFC7644 §3.1", res.isScimMediaType(), "Content-Type is application/scim+json", s.fmt("got {s}", .{res.content_type orelse "(none)"}));
    }

    /// Checks an error response body (RFC 7644 §3.12): the Error schema,
    /// `status` as a JSON string and, for 400/409, the `scimType`.
    fn expectError(s: *Suite, level: Level, ref: []const u8, res: Client.Response, want: http.Status, scim_type: ?[]const u8, what: []const u8) void {
        if (!s.expectStatus(level, ref, res, want, what)) return;
        const body = res.json(s.arena);
        const status = j.string(j.field(body, "status"));
        const code = s.fmt("{d}", .{@intFromEnum(want)});
        _ = s.check(.must, "RFC7644 §3.12", j.hasSchema(body, urn.@"error") and eql(status, code), s.fmt("  error body has the Error schema and status \"{s}\"", .{code}), res.body);
        if (scim_type) |t| {
            _ = s.check(.should, "RFC7644 §3.12", eql(j.string(j.field(body, "scimType")), t), s.fmt("  scimType is {s}", .{t}), res.body);
        }
    }

    fn expectList(s: *Suite, ref: []const u8, res: Client.Response, what: []const u8) ?Value {
        if (!s.expectStatus(.must, ref, res, .ok, what)) return null;
        const body = res.json(s.arena);
        const ok = j.hasSchema(body, urn.list_response) and j.integer(j.field(body, "totalResults")) != null;
        if (!s.check(.must, "RFC7644 §3.4.2", ok, "  body is a ListResponse with totalResults", res.body)) return null;
        return body;
    }

    fn expectCount(s: *Suite, ref: []const u8, level: Level, expr: []const u8, want: i64, what: []const u8) void {
        const res = s.send(.GET, s.fmt("{s}?filter={s}", .{ s.users_endpoint, s.escape(expr) }), .{}) orelse return;
        if (res.status != .ok) {
            _ = s.check(level, ref, false, what, s.fmt("filter={s} got HTTP {d}: {s}", .{ expr, @intFromEnum(res.status), res.body }));
            return;
        }
        const total = j.integer(j.field(res.json(s.arena), "totalResults"));
        _ = s.check(level, ref, total == want, what, s.fmt("filter={s} expected totalResults {d}, got {?d}", .{ expr, want, total }));
    }

    fn expectPatchStatus(s: *Suite, ref: []const u8, res: Client.Response, what: []const u8) bool {
        const ok = res.status == .ok or res.status == .no_content;
        return s.check(.must, ref, ok, s.fmt("{s} returns 200 or 204", .{what}), s.fmt("got HTTP {d}: {s}", .{ @intFromEnum(res.status), res.body }));
    }

    /// Applies one PATCH operation and, when `attr` is given, verifies the
    /// resulting value with a follow-up GET.
    fn expectPatch(s: *Suite, ref: []const u8, path: []const u8, op: []const u8, what: []const u8, attr: ?[]const u8, want: ?[]const u8) void {
        const res = s.send(.PATCH, path, .{ .body = patchJson(s, op) }) orelse return;
        if (!s.expectPatchStatus(ref, res, what)) return;
        const name = attr orelse return;
        const got = s.send(.GET, path, .{}) orelse return;
        const actual = j.string(j.path(got.json(s.arena), name));
        _ = s.check(.must, ref, eql(actual, want.?), s.fmt("{s}: {s} is \"{s}\"", .{ what, name, want.? }), got.body);
    }

    fn userJson(s: *Suite, user_name: []const u8, display_name: []const u8) []const u8 {
        return s.fmt(
            \\{{"schemas":["{s}"],"userName":{f},"externalId":{f},"name":{{"givenName":"Barbara","familyName":"Jensen"}},"displayName":{f},"emails":[{{"value":{f},"type":"work","primary":true}}],"active":true,"password":"t1meMa$heen!"}}
        , .{
            urn.user,
            std.json.fmt(user_name, .{}),
            std.json.fmt(user_name, .{}),
            std.json.fmt(display_name, .{}),
            std.json.fmt(s.fmt("{s}@example.com", .{user_name}), .{}),
        });
    }
};

fn patchJson(s: *Suite, operation: []const u8) []const u8 {
    return s.fmt("{{\"schemas\":[\"{s}\"],\"Operations\":[{s}]}}", .{ urn.patch_op, operation });
}

fn eql(actual: ?[]const u8, expected: []const u8) bool {
    return actual != null and std.mem.eql(u8, actual.?, expected);
}

fn lenOf(items: ?[]const Value) usize {
    return (items orelse return 0).len;
}

fn resourceCount(list: Value) usize {
    return (j.array(j.field(list, "Resources")) orelse return 0).len;
}

/// A loose xsd:dateTime check (RFC 7643 §2.3.5): `YYYY-MM-DDThh:mm:ss...`.
fn isDateTime(v: ?[]const u8) bool {
    const s = v orelse return false;
    return s.len >= 19 and s[4] == '-' and s[7] == '-' and (s[10] == 'T' or s[10] == 't') and s[13] == ':' and s[16] == ':';
}

fn truncate(s: []const u8) []const u8 {
    return if (s.len > 300) s[0..300] else s;
}

test isDateTime {
    try std.testing.expect(isDateTime("2026-09-25T05:32:58.982726121Z"));
    try std.testing.expect(isDateTime("2011-08-01T18:29:49.793Z"));
    try std.testing.expect(!isDateTime("yesterday"));
    try std.testing.expect(!isDateTime(null));
}
