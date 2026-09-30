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
    const wrong_type = s.fmt("{{\"schemas\":[\"{s}\"],\"userName\":{f},\"active\":\"yes\"}}", .{ urn.user, std.json.fmt(s.userName("wrongtype"), .{}) });
    if (s.send(.POST, s.users_endpoint, .{ .body = wrong_type })) |res| {
        s.expectError(.must, "RFC7643 §2.3", res, .bad_request, null, "POST a string where a boolean is defined returns 400");
        s.trackCreated(s.users_endpoint, res);
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
