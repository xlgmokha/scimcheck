//! RFC 7644 §2: requests must be authenticated. scimcheck assumes the
//! bearer token scheme of RFC 6750 when a token is configured.
const std = @import("std");

const check = @import("../check.zig");
const Suite = check.Suite;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §2";
    if (s.client.authorization == null) return s.skip("no credentials configured (--token)");

    if (s.send(.GET, s.users_endpoint, .{ .authenticate = false })) |res| {
        if (s.expectStatus(.must, ref, res, .unauthorized, "a request without credentials returns 401")) {
            _ = s.check(.must, "RFC7235 §3.1", res.www_authenticate != null, "  401 response includes WWW-Authenticate", null);
            s.expectErrorBody(res, null);
        }
    }
    if (s.send(.GET, s.users_endpoint, .{ .authorization = "Bearer scimcheck-invalid-token" })) |res| {
        if (s.expectStatus(.must, ref, res, .unauthorized, "an invalid bearer token returns 401")) {
            const challenge = res.www_authenticate orelse "";
            _ = s.check(.should, "RFC6750 §3.1", std.mem.find(u8, challenge, "invalid_token") != null, "  WWW-Authenticate carries error=\"invalid_token\"", challenge);
        }
    }
    if (s.send(.GET, s.users_endpoint, .{ .authorization = "Bearer" })) |res| {
        _ = s.expectStatusIn(.must, "RFC6750 §3.1", res, &.{ .bad_request, .unauthorized }, "a Bearer scheme without a token returns 400 or 401");
    }
    if (s.send(.GET, s.users_endpoint, .{ .authorization = "Basic c2NpbWNoZWNrOm5vcGU=" })) |res| {
        _ = s.expectStatus(.must, ref, res, .unauthorized, "an unsupported authentication scheme returns 401");
    }
    if (s.send(.GET, "/ServiceProviderConfig", .{ .authenticate = false })) |res| {
        _ = s.expectStatusIn(.may, "RFC7644 §4", res, &.{.ok}, "discovery endpoints are readable without credentials");
    }
}
