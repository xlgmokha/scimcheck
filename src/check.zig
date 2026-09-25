//! Conformance checks for SCIM 2.0 service providers.
//!
//! Each check cites the RFC 7643 / RFC 7644 section it verifies and has a
//! level that mirrors the RFC 2119 keyword: a violated MUST fails the run, a
//! violated SHOULD is a warning, and an unsupported MAY is reported as
//! information. Optional features (PATCH, filtering, sorting, ETags, bulk)
//! are skipped when `/ServiceProviderConfig` says they are unsupported.
//!
//! This file holds the suite's machinery (reporting, assertions, fixtures,
//! cleanup). The checks themselves live in `checks/`, one file per section.
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

pub const Level = enum { must, should, may };

pub const Section = enum {
    discovery,
    auth,
    errors,
    users,
    extensions,
    attributes,
    filter,
    search,
    pagination,
    sort,
    patch,
    etag,
    groups,
    bulk,

    pub fn title(s: Section) []const u8 {
        return switch (s) {
            .discovery => "Discovery (RFC 7644 §4, RFC 7643 §5-7)",
            .auth => "Authentication (RFC 7644 §2, RFC 6750)",
            .errors => "Errors and HTTP semantics (RFC 7644 §3.12, §3.11)",
            .users => "Users CRUD (RFC 7644 §3.3-3.6, RFC 7643 §4.1)",
            .extensions => "Schema extensions (RFC 7643 §3.3, §4.3)",
            .attributes => "Attribute selection (RFC 7644 §3.9-3.10)",
            .filter => "Filtering (RFC 7644 §3.4.2.2)",
            .search => "Search with POST (RFC 7644 §3.4.3)",
            .pagination => "Pagination (RFC 7644 §3.4.2.4)",
            .sort => "Sorting (RFC 7644 §3.4.2.3)",
            .patch => "PATCH (RFC 7644 §3.5.2)",
            .etag => "Versioning (RFC 7644 §3.14, RFC 7232)",
            .groups => "Groups (RFC 7643 §4.2)",
            .bulk => "Bulk (RFC 7644 §3.7)",
        };
    }

    fn run(s: Section) *const fn (*Suite) void {
        return switch (s) {
            .discovery => @import("checks/discovery.zig").run,
            .auth => @import("checks/auth.zig").run,
            .errors => @import("checks/errors.zig").run,
            .users => @import("checks/users.zig").run,
            .extensions => @import("checks/extensions.zig").run,
            .attributes => @import("checks/attributes.zig").run,
            .filter => @import("checks/filter.zig").run,
            .search => @import("checks/search.zig").run,
            .pagination => @import("checks/pagination.zig").run,
            .sort => @import("checks/sort.zig").run,
            .patch => @import("checks/patch.zig").run,
            .etag => @import("checks/etag.zig").run,
            .groups => @import("checks/groups.zig").run,
            .bulk => @import("checks/bulk.zig").run,
        };
    }
};

pub const Options = struct {
    /// Run only these sections. Discovery always runs.
    only: std.EnumSet(Section) = .initFull(),
    /// Leave the resources created by the run on the server.
    keep: bool = false,
};

pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    warned: usize = 0,
    info: usize = 0,
    skipped: usize = 0,
};

/// Features advertised in `/ServiceProviderConfig` (RFC 7643 §5). Unknown
/// features are assumed supported so their checks still run.
pub const Capabilities = struct {
    patch: bool = true,
    bulk: bool = true,
    filter: bool = true,
    sort: bool = true,
    etag: bool = true,
    max_results: ?i64 = null,
    bulk_max_operations: ?i64 = null,
};

/// A user created by the suite. The three shared fixtures sort differently
/// by userName, name.givenName and primary email so sorting can be verified.
pub const Fixture = struct {
    id: []const u8,
    user_name: []const u8,
    path: []const u8,
    given_name: []const u8,
    email: []const u8,
    external_id: []const u8,
    employee_number: []const u8,
};

/// What to put in a User created by the suite.
pub const UserSpec = struct {
    user_name: []const u8,
    display_name: []const u8 = "Barbara Jensen",
    given_name: []const u8 = "Barbara",
    family_name: []const u8 = "Jensen",
    email: ?[]const u8 = null,
    external_id: ?[]const u8 = null,
    active: bool = true,
    /// A JSON object for the enterprise extension, sent only when the
    /// server advertises that extension on User.
    enterprise: ?[]const u8 = null,
    /// Extra JSON members, e.g. `"nickName":"Babs",`.
    extra: []const u8 = "",
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
    /// The User resource type lists the enterprise extension.
    enterprise_user: bool = false,
    run_id: []const u8 = "",
    /// Resources created by the run, deleted at the end unless `keep` is set.
    created: std.ArrayList([]const u8) = .empty,
    fixtures: ?[3]Fixture = null,
    fixtures_failed: bool = false,

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
        for (std.enums.values(Section)) |section| {
            // Discovery always runs: it tells us which endpoints and features exist.
            if (section != .discovery and !s.options.only.contains(section)) continue;
            s.print("\n{s}\n", .{section.title()});
            section.run()(s);
        }
        s.cleanup();
        s.print("\n{d} passed, {d} failed, {d} warnings, {d} info, {d} skipped\n", .{
            s.summary.passed, s.summary.failed, s.summary.warned, s.summary.info, s.summary.skipped,
        });
        s.out.flush() catch {};
        return s.summary;
    }

    // ------------------------------------------------------------------
    // Reporting
    // ------------------------------------------------------------------

    pub fn print(s: *Suite, comptime format: []const u8, args: anytype) void {
        s.out.print(format, args) catch {};
    }

    pub fn fmt(s: *Suite, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(s.arena, format, args) catch "(out of memory)";
    }

    pub fn escape(s: *Suite, value: []const u8) []const u8 {
        return Client.queryEscape(s.arena, value) catch "";
    }

    pub fn json(s: *Suite, res: Client.Response) ?Value {
        return res.json(s.arena);
    }

    pub fn skip(s: *Suite, why: []const u8) void {
        s.summary.skipped += 1;
        s.print("  SKIP  {s}\n", .{why});
    }

    /// Records one check. Returns `ok` so callers can gate follow-up checks.
    pub fn check(s: *Suite, level: Level, ref: []const u8, ok: bool, what: []const u8, detail: ?[]const u8) bool {
        const tag = if (ok) "PASS" else switch (level) {
            .must => "FAIL",
            .should => "WARN",
            .may => "INFO",
        };
        if (ok) {
            s.summary.passed += 1;
        } else switch (level) {
            .must => s.summary.failed += 1,
            .should => s.summary.warned += 1,
            .may => s.summary.info += 1,
        }
        s.print("  {s}  {s} [{s}]\n", .{ tag, what, ref });
        if (!ok) if (detail) |d| s.print("        {s}\n", .{truncate(d)});
        s.out.flush() catch {};
        return ok;
    }

    // ------------------------------------------------------------------
    // Requests and assertions
    // ------------------------------------------------------------------

    pub fn send(s: *Suite, method: http.Method, target: []const u8, options: Client.Options) ?Client.Response {
        return s.client.send(s.arena, method, target, options) catch |err| {
            _ = s.check(.must, "transport", false, s.fmt("{s} {s}", .{ @tagName(method), target }), s.fmt("request failed: {s}", .{@errorName(err)}));
            return null;
        };
    }

    /// GETs `path` for a follow-up verification and returns its body, or
    /// records a failure and returns null.
    pub fn fetch(s: *Suite, ref: []const u8, path: []const u8) ?Value {
        const res = s.send(.GET, path, .{}) orelse return null;
        if (res.status != .ok) {
            _ = s.check(.must, ref, false, s.fmt("GET {s} returns 200", .{path}), s.fmt("got HTTP {d}: {s}", .{ @intFromEnum(res.status), res.body }));
            return null;
        }
        return s.json(res);
    }

    pub fn expectStatus(s: *Suite, level: Level, ref: []const u8, res: Client.Response, want: http.Status, what: []const u8) bool {
        return s.check(level, ref, res.status == want, what, s.fmt("got HTTP {d}: {s}", .{ @intFromEnum(res.status), res.body }));
    }

    pub fn expectStatusIn(s: *Suite, level: Level, ref: []const u8, res: Client.Response, want: []const http.Status, what: []const u8) bool {
        const ok = std.mem.findScalar(http.Status, want, res.status) != null;
        return s.check(level, ref, ok, what, s.fmt("got HTTP {d}: {s}", .{ @intFromEnum(res.status), res.body }));
    }

    pub fn expectMediaType(s: *Suite, res: Client.Response) void {
        _ = s.check(.must, "RFC7644 §3.1", res.isScimMediaType(), "Content-Type is application/scim+json", s.fmt("got {s}", .{res.content_type orelse "(none)"}));
    }

    /// RFC 7644 Table 9: the only `scimType` values the protocol defines.
    const scim_types = [_][]const u8{ "invalidFilter", "tooMany", "uniqueness", "mutability", "invalidSyntax", "invalidPath", "noTarget", "invalidValue", "invalidVers", "sensitive" };

    /// Checks an error response (RFC 7644 §3.12): the status, the Error
    /// schema, `status` as a JSON string and, when given, the `scimType`.
    pub fn expectError(s: *Suite, level: Level, ref: []const u8, res: Client.Response, want: http.Status, scim_type: ?[]const u8, what: []const u8) void {
        if (!s.expectStatus(level, ref, res, want, what)) return;
        s.expectErrorBody(res, scim_type);
    }

    pub fn expectErrorBody(s: *Suite, res: Client.Response, scim_type: ?[]const u8) void {
        const body = s.json(res);
        const status = j.string(j.field(body, "status"));
        const code = s.fmt("{d}", .{@intFromEnum(res.status)});
        _ = s.check(.must, "RFC7644 §3.12", j.hasSchema(body, urn.@"error") and eql(status, code), s.fmt("  error body has the Error schema and status \"{s}\"", .{code}), res.body);
        const actual = j.string(j.field(body, "scimType"));
        if (scim_type) |t| {
            _ = s.check(.should, "RFC7644 §3.12", eql(actual, t), s.fmt("  scimType is {s}", .{t}), res.body);
        } else if (actual) |a| {
            var known = false;
            for (scim_types) |t| known = known or std.mem.eql(u8, t, a);
            _ = s.check(.should, "RFC7644 §3.12", known, s.fmt("  scimType {s} is one of the values in Table 9", .{a}), null);
        }
    }

    /// Checks a ListResponse (RFC 7644 §3.4.2) and returns its body.
    pub fn expectList(s: *Suite, ref: []const u8, res: Client.Response, what: []const u8) ?Value {
        if (!s.expectStatus(.must, ref, res, .ok, what)) return null;
        const body = s.json(res);
        const total = j.integer(j.field(body, "totalResults"));
        if (!s.check(.must, "RFC7644 §3.4.2", j.hasSchema(body, urn.list_response) and total != null, "  body is a ListResponse with totalResults", res.body)) return null;
        const resources = j.field(body, "Resources");
        if (resources != null and j.array(resources) == null) {
            _ = s.check(.must, "RFC7644 §3.4.2", false, "  Resources is an array", res.body);
            return null;
        }
        if (resourceCount(body.?) > 0) {
            if (j.integer(j.field(body, "itemsPerPage"))) |per_page| {
                _ = s.check(.must, "RFC7644 §3.4.2", per_page == @as(i64, @intCast(resourceCount(body.?))), "  itemsPerPage equals the number of Resources", res.body);
            }
        }
        return body;
    }

    /// Runs a filter against the User endpoint and checks `totalResults`.
    pub fn expectCount(s: *Suite, ref: []const u8, level: Level, expr: []const u8, want: i64, what: []const u8) void {
        s.expectCountAt(s.users_endpoint, ref, level, expr, want, what);
    }

    pub fn expectCountAt(s: *Suite, endpoint: []const u8, ref: []const u8, level: Level, expr: []const u8, want: i64, what: []const u8) void {
        const res = s.send(.GET, s.fmt("{s}?filter={s}", .{ endpoint, s.escape(expr) }), .{}) orelse return;
        if (res.status != .ok) {
            _ = s.check(level, ref, false, what, s.fmt("filter={s} got HTTP {d}: {s}", .{ expr, @intFromEnum(res.status), res.body }));
            return;
        }
        const total = j.integer(j.field(s.json(res), "totalResults"));
        _ = s.check(level, ref, total == want, what, s.fmt("filter={s} expected totalResults {d}, got {?d}", .{ expr, want, total }));
    }

    /// Checks that a PATCH succeeded: 200 with the resource, or 204.
    pub fn patchOk(s: *Suite, ref: []const u8, res: Client.Response, what: []const u8) bool {
        return s.expectStatusIn(.must, ref, res, &.{ .ok, .no_content }, s.fmt("{s} returns 200 or 204", .{what}));
    }

    /// Applies PATCH operations (JSON objects separated by commas) and,
    /// when `attr` is given, verifies the resulting string value with a GET.
    pub fn expectPatch(s: *Suite, ref: []const u8, path: []const u8, ops: []const u8, what: []const u8, attr: ?[]const u8, want: ?[]const u8) void {
        const res = s.send(.PATCH, path, .{ .body = s.patchJson(ops) }) orelse return;
        if (!s.patchOk(ref, res, what)) return;
        const name = attr orelse return;
        const body = s.fetch(ref, path) orelse return;
        _ = s.check(.must, ref, eql(j.string(j.path(body, name)), want.?), s.fmt("  {s} is \"{s}\"", .{ name, want.? }), s.fmt("{f}", .{std.json.fmt(body, .{})}));
    }

    pub fn patchJson(s: *Suite, operations: []const u8) []const u8 {
        return s.fmt("{{\"schemas\":[\"{s}\"],\"Operations\":[{s}]}}", .{ urn.patch_op, operations });
    }

    // ------------------------------------------------------------------
    // Resources created by the suite
    // ------------------------------------------------------------------

    pub fn userJson(s: *Suite, spec: UserSpec) []const u8 {
        const email = spec.email orelse s.fmt("{s}@example.com", .{spec.user_name});
        const with_extension = spec.enterprise != null and s.enterprise_user;
        const schemas = if (with_extension)
            s.fmt("\"{s}\",\"{s}\"", .{ urn.user, urn.enterprise_user })
        else
            s.fmt("\"{s}\"", .{urn.user});
        const enterprise = if (with_extension) s.fmt(",\"{s}\":{s}", .{ urn.enterprise_user, spec.enterprise.? }) else "";
        return s.fmt(
            \\{{"schemas":[{s}],{s}"userName":{f},"externalId":{f},"name":{{"givenName":{f},"familyName":{f}}},"displayName":{f},"emails":[{{"value":{f},"type":"work","primary":true}}],"active":{},"password":"t1meMa$heen!"{s}}}
        , .{
            schemas,
            spec.extra,
            std.json.fmt(spec.user_name, .{}),
            std.json.fmt(spec.external_id orelse spec.user_name, .{}),
            std.json.fmt(spec.given_name, .{}),
            std.json.fmt(spec.family_name, .{}),
            std.json.fmt(spec.display_name, .{}),
            std.json.fmt(email, .{}),
            spec.active,
            enterprise,
        });
    }

    /// Creates a user as setup (not a check), tracks it for cleanup and
    /// returns it. Reports a SKIP when creation fails.
    pub fn createUser(s: *Suite, spec: UserSpec) ?Fixture {
        const res = s.client.send(s.arena, .POST, s.users_endpoint, .{ .body = s.userJson(spec) }) catch |err| {
            s.skip(s.fmt("could not create user {s}: {s}", .{ spec.user_name, @errorName(err) }));
            return null;
        };
        const id = j.string(j.field(s.json(res), "id"));
        if (res.status != .created or id == null) {
            s.skip(s.fmt("could not create user {s}: HTTP {d} {s}", .{ spec.user_name, @intFromEnum(res.status), truncate(res.body) }));
            return null;
        }
        const path = s.fmt("{s}/{s}", .{ s.users_endpoint, id.? });
        s.created.append(s.arena, path) catch {};
        return .{
            .id = id.?,
            .user_name = spec.user_name,
            .path = path,
            .given_name = spec.given_name,
            .email = spec.email orelse s.fmt("{s}@example.com", .{spec.user_name}),
            .external_id = spec.external_id orelse spec.user_name,
            .employee_number = "",
        };
    }

    /// A unique userName for a throwaway user.
    pub fn userName(s: *Suite, label: []const u8) []const u8 {
        return s.fmt("scimcheck-{s}-{s}", .{ s.run_id, label });
    }

    pub fn fixturePrefix(s: *Suite) []const u8 {
        return s.fmt("scimcheck-{s}-f", .{s.run_id});
    }

    /// Creates the three shared users once: alice, bob and carol. They sort
    /// alice < bob < carol by userName, but bob < carol < alice by
    /// name.givenName and by primary email. carol is inactive.
    pub fn requireFixtures(s: *Suite) ?[3]Fixture {
        if (s.fixtures) |f| return f;
        if (s.fixtures_failed) {
            s.skip("fixtures are unavailable");
            return null;
        }
        const specs = [_]struct { []const u8, []const u8, []const u8, bool, []const u8 }{
            .{ "alice", "Charlie", "c", true, "Eng" },
            .{ "bob", "Alpha", "a", true, "Eng" },
            .{ "carol", "Bravo", "b", false, "Sales" },
        };
        var result: [3]Fixture = undefined;
        for (specs, 0..) |spec, i| {
            const who, const given, const letter, const active, const department = spec;
            const user_name = s.fmt("{s}-{s}", .{ s.fixturePrefix(), who });
            const employee_number = s.fmt("{s}-{d}", .{ s.run_id, i + 1 });
            var fixture = s.createUser(.{
                .user_name = user_name,
                .display_name = who,
                .given_name = given,
                .email = s.fmt("{s}.{s}@example.com", .{ letter, user_name }),
                .external_id = s.fmt("Ext-{s}", .{user_name}),
                .active = active,
                .enterprise = s.fmt("{{\"employeeNumber\":{f},\"department\":{f}}}", .{ std.json.fmt(employee_number, .{}), std.json.fmt(department, .{}) }),
            }) orelse {
                s.fixtures_failed = true;
                return null;
            };
            fixture.employee_number = employee_number;
            result[i] = fixture;
        }
        s.fixtures = result;
        return result;
    }

    /// Tracks a resource a check created, e.g. by mistake in a negative
    /// check, so cleanup removes it.
    pub fn trackCreated(s: *Suite, endpoint: []const u8, res: Client.Response) void {
        if (res.status != .created) return;
        const id = j.string(j.field(s.json(res), "id")) orelse return;
        s.created.append(s.arena, s.fmt("{s}/{s}", .{ endpoint, id })) catch {};
    }

    pub fn untrack(s: *Suite, path: []const u8) void {
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
};

pub fn eql(actual: ?[]const u8, expected: []const u8) bool {
    return actual != null and std.mem.eql(u8, actual.?, expected);
}

pub fn lenOf(items: ?[]const Value) usize {
    return (items orelse return 0).len;
}

pub fn resourceCount(list: Value) usize {
    return lenOf(j.array(j.field(list, "Resources")));
}

/// The first resource of a ListResponse.
pub fn firstResource(list: ?Value) ?Value {
    const resources = j.array(j.field(list, "Resources")) orelse return null;
    return if (resources.len > 0) resources[0] else null;
}

/// Counts elements of a multi-valued attribute with `"primary": true`.
pub fn primaryCount(items: ?[]const Value) usize {
    var n: usize = 0;
    for (items orelse &.{}) |item| {
        if (j.boolean(j.field(item, "primary")) == true) n += 1;
    }
    return n;
}

/// A loose xsd:dateTime check (RFC 7643 §2.3.5): `YYYY-MM-DDThh:mm:ss...`.
pub fn isDateTime(v: ?[]const u8) bool {
    const s = v orelse return false;
    return s.len >= 19 and s[4] == '-' and s[7] == '-' and (s[10] == 'T' or s[10] == 't') and s[13] == ':' and s[16] == ':';
}

/// An entity tag per RFC 7232 §2.3: `"opaque"` or `W/"opaque"`.
pub fn isEntityTag(v: ?[]const u8) bool {
    var s = v orelse return false;
    if (std.mem.startsWith(u8, s, "W/")) s = s[2..];
    return s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"' and std.mem.findScalar(u8, s[1 .. s.len - 1], '"') == null;
}

pub fn truncate(s: []const u8) []const u8 {
    return if (s.len > 300) s[0..300] else s;
}

test isDateTime {
    try std.testing.expect(isDateTime("2026-09-25T05:32:58.982726121Z"));
    try std.testing.expect(isDateTime("2011-08-01T18:29:49.793Z"));
    try std.testing.expect(!isDateTime("yesterday"));
    try std.testing.expect(!isDateTime(null));
}

test isEntityTag {
    try std.testing.expect(isEntityTag("W/\"3694e05e9dff590\""));
    try std.testing.expect(isEntityTag("\"abc\""));
    try std.testing.expect(!isEntityTag("abc"));
    try std.testing.expect(!isEntityTag("W/abc"));
    try std.testing.expect(!isEntityTag("\"a\"b\""));
}

test "every section compiles" {
    inline for (comptime std.enums.values(Section)) |section| _ = section.run();
}
