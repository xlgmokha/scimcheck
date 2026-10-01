//! RFC 7644 §3.12 error responses, the /Me alias (§3.11) and the HTTP
//! semantics every endpoint shares.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.12";
    const missing = s.fmt("{s}/scimcheck-{s}-missing", .{ s.users_endpoint, s.run_id });

    if (s.send(.GET, missing, .{})) |res| {
        s.expectError(.must, "RFC7644 §3.4.1", res, .not_found, null, "GET an unknown User returns 404");
    }
    if (s.send(.PUT, missing, .{ .body = s.userJson(.{ .user_name = s.userName("ghost") }) })) |res| {
        s.expectError(.must, "RFC7644 §3.5.1", res, .not_found, null, "PUT an unknown User returns 404");
        s.trackCreated(s.users_endpoint, res);
    }
    if (s.caps.patch) {
        if (s.send(.PATCH, missing, .{ .body = s.patchJson("{\"op\":\"replace\",\"path\":\"displayName\",\"value\":\"x\"}") })) |res| {
            s.expectError(.must, "RFC7644 §3.5.2", res, .not_found, null, "PATCH an unknown User returns 404");
        }
    }
    if (s.send(.DELETE, missing, .{})) |res| {
        s.expectError(.must, "RFC7644 §3.6", res, .not_found, null, "DELETE an unknown User returns 404");
    }
    if (s.send(.GET, "/ScimcheckUnknownEndpoint", .{})) |res| {
        s.expectError(.should, ref, res, .not_found, null, "GET an unknown endpoint returns 404");
    }

    if (s.send(.POST, s.users_endpoint, .{ .body = "{\"schemas\": [" })) |res| {
        s.expectError(.must, ref, res, .bad_request, "invalidSyntax", "POST malformed JSON returns 400 invalidSyntax");
    }
    const no_user_name = s.fmt("{{\"schemas\":[\"{s}\"],\"displayName\":\"no username\"}}", .{urn.user});
    if (s.send(.POST, s.users_endpoint, .{ .body = no_user_name })) |res| {
        s.expectError(.must, "RFC7643 §4.1", res, .bad_request, "invalidValue", "POST a User without the required userName returns 400 invalidValue");
        s.trackCreated(s.users_endpoint, res);
    }
    // RFC 7643 §4.1.1: "Each User MUST include a non-empty userName value."
    inline for (.{ "\"\"", "null" }) |value| {
        const body = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{s},\"displayName\":\"empty username\"}}", .{ urn.user, value });
        if (s.send(.POST, s.users_endpoint, .{ .body = body })) |res| {
            s.expectError(.must, "RFC7643 §4.1.1", res, .bad_request, "invalidValue", "POST a User with userName " ++ value ++ " returns 400 invalidValue");
            s.trackCreated(s.users_endpoint, res);
        }
    }
    const no_schemas = s.fmt("{{\"userName\":{f}}}", .{std.json.fmt(s.userName("noschemas"), .{})});
    if (s.send(.POST, s.users_endpoint, .{ .body = no_schemas })) |res| {
        s.expectError(.must, "RFC7643 §3", res, .bad_request, null, "POST a resource without the required schemas returns 400");
        s.trackCreated(s.users_endpoint, res);
    }
    const unknown_schema = s.fmt("{{\"schemas\":[\"urn:scimcheck:unknown\"],\"userName\":{f}}}", .{std.json.fmt(s.userName("badschema"), .{})});
    if (s.send(.POST, s.users_endpoint, .{ .body = unknown_schema })) |res| {
        s.expectError(.must, "RFC7643 §3", res, .bad_request, null, "POST a resource with an unknown schema URN returns 400");
        s.trackCreated(s.users_endpoint, res);
    }
    const duplicate_schema = s.fmt("{{\"schemas\":[\"{s}\",\"{s}\"],\"userName\":{f}}}", .{ urn.user, urn.user, std.json.fmt(s.userName("dupschema"), .{}) });
    if (s.send(.POST, s.users_endpoint, .{ .body = duplicate_schema })) |res| {
        s.expectError(.must, "RFC7643 §3", res, .bad_request, null, "POST a resource with a duplicated schemas value returns 400");
        s.trackCreated(s.users_endpoint, res);
    }
    // RFC 7643 §3: "Value order is not specified and MUST NOT impact
    // behavior." Only meaningful with two schemas to reorder.
    if (s.enterprise_user) {
        const extra = "{\"employeeNumber\":\"1\"}";
        const forward = s.fmt("{{\"schemas\":[\"{s}\",\"{s}\"],\"userName\":{f},\"{s}\":{s}}}", .{ urn.user, urn.enterprise_user, std.json.fmt(s.userName("order-fwd"), .{}), urn.enterprise_user, extra });
        const reversed = s.fmt("{{\"schemas\":[\"{s}\",\"{s}\"],\"userName\":{f},\"{s}\":{s}}}", .{ urn.enterprise_user, urn.user, std.json.fmt(s.userName("order-rev"), .{}), urn.enterprise_user, extra });
        var forward_status: ?std.http.Status = null;
        if (s.send(.POST, s.users_endpoint, .{ .body = forward })) |res| {
            forward_status = res.status;
            s.trackCreated(s.users_endpoint, res);
        }
        if (forward_status) |want| {
            if (s.send(.POST, s.users_endpoint, .{ .body = reversed })) |res| {
                s.trackCreated(s.users_endpoint, res);
                _ = s.check(.must, "RFC7643 §3", res.status == want, "schemas array order does not affect acceptance", s.fmt("forward order: HTTP {d}, reversed order: HTTP {d}", .{ @intFromEnum(want), @intFromEnum(res.status) }));
            }
        }
    }
    const wrong_type = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f},\"active\":\"yes\"}}", .{ urn.user, std.json.fmt(s.userName("wrongtype"), .{}) });
    if (s.send(.POST, s.users_endpoint, .{ .body = wrong_type })) |res| {
        s.expectError(.must, "RFC7643 §2.3", res, .bad_request, null, "POST a string where a boolean is defined returns 400");
        s.trackCreated(s.users_endpoint, res);
    }
    // RFC 7643 §2.2/§2.3: a value of the wrong plurality or JSON type.
    const wrong_shapes = [_]struct { what: []const u8, extra: []const u8 }{
        .{ .what = "a string where emails (multi-valued) is defined", .extra = "\"emails\":\"a@example.com\"" },
        .{ .what = "an array where displayName (single-valued) is defined", .extra = "\"displayName\":[\"x\"]" },
        .{ .what = "a number where displayName (a string) is defined", .extra = "\"displayName\":42" },
    };
    for (wrong_shapes) |shape| {
        const body = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f},{s}}}", .{ urn.user, std.json.fmt(s.userName("wrongshape"), .{}), shape.extra });
        if (s.send(.POST, s.users_endpoint, .{ .body = body })) |res| {
            s.trackCreated(s.users_endpoint, res);
            if (res.status == .created) {
                _ = s.check(.should, "RFC7643 §2.2", false, s.fmt("POST {s} returns 400", .{shape.what}), "the server accepted (and may have coerced) the value");
            } else {
                s.expectError(.should, "RFC7643 §2.2", res, .bad_request, null, s.fmt("POST {s} returns 400", .{shape.what}));
            }
        }
    }
    const bad_binary = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f},\"x509Certificates\":[{{\"value\":\"!!!not base64\"}}]}}", .{ urn.user, std.json.fmt(s.userName("badbinary"), .{}) });
    if (s.send(.POST, s.users_endpoint, .{ .body = bad_binary })) |res| {
        s.expectError(.must, "RFC7643 §2.3.6", res, .bad_request, null, "POST a binary value that is not base64 returns 400");
        s.trackCreated(s.users_endpoint, res);
    }

    if (s.send(.DELETE, s.users_endpoint, .{})) |res| {
        if (s.expectStatus(.should, "RFC9110 §15.5.6", res, .method_not_allowed, "DELETE on a collection returns 405")) {
            _ = s.check(.must, "RFC9110 §15.5.6", res.allow != null, "  405 response includes an Allow header", null);
            s.expectErrorBody(res, null);
        }
    }

    // RFC 7644 §3.11: /Me is optional; a server without it returns 501.
    if (s.send(.GET, "/Me", .{})) |res| {
        if (s.expectStatusIn(.should, "RFC7644 §3.11", res, &.{ .ok, .permanent_redirect, .not_implemented }, "GET /Me returns 200, 308, or 501 when unsupported")) {
            if (res.status == .not_implemented) s.expectErrorBody(res, null);
            if (res.status == .ok) {
                // "A service provider MAY process the SCIM request directly.
                // In any response, the HTTP 'Location' header MUST be the
                // permanent location of the aliased resource..."
                _ = s.check(.must, "RFC7644 §3.11", res.location != null, "  a 200 response includes a Location header", null);
            }
        }
    }

    // RFC 7644 §3.12 lists 413 for requests over the server's limits.
    const big = s.arena.alloc(u8, 2 << 20) catch return;
    @memset(big, 'x');
    const oversized = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f},\"displayName\":\"{s}\"}}", .{ urn.user, std.json.fmt(s.userName("huge"), .{}), big });
    if (s.send(.POST, s.users_endpoint, .{ .body = oversized })) |res| {
        _ = s.expectStatus(.may, ref, res, .payload_too_large, "a 2 MiB request body returns 413");
        s.trackCreated(s.users_endpoint, res);
    }
}
