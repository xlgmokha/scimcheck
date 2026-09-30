//! RFC 7644 §2: requests must be authenticated. scimcheck assumes the
//! bearer token scheme of RFC 6750 when a token is configured.
const std = @import("std");

const check = @import("../check.zig");
const Suite = check.Suite;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §2";
    transport(s);
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

/// RFC 7644 §7.2: clients and service providers MUST require TLS. A loopback
/// address is a local test deployment, so it is skipped rather than failed.
fn transport(s: *Suite) void {
    const url = s.client.base_url;
    if (isLoopback(url)) return s.skip("TLS is not checked for a loopback address");
    _ = s.check(.must, "RFC7644 §7.2", std.ascii.startsWithIgnoreCase(url, "https://"), "the service provider is reached over TLS (https)", url);
}

fn isLoopback(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const component = uri.host orelse return false;
    var buffer: [255]u8 = undefined;
    const host = component.toRaw(&buffer) catch return false;
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1");
}

test isLoopback {
    try std.testing.expect(isLoopback("http://localhost:8080/scim/v2"));
    try std.testing.expect(isLoopback("http://127.0.0.1/scim"));
    try std.testing.expect(!isLoopback("http://scim.example.com/scim/v2"));
    try std.testing.expect(!isLoopback("https://example.com"));
}
