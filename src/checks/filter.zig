//! The filter grammar and its evaluation rules (RFC 7644 §3.4.2.2), run
//! against the three fixtures. Every query is anchored with
//! `userName sw "<prefix>"` so other data on the server does not interfere.
const std = @import("std");

const check = @import("../check.zig");
const j = @import("../json.zig");
const Suite = check.Suite;
const urn = check.urn;

pub fn run(s: *Suite) void {
    const ref = "RFC7644 §3.4.2.2";
    if (!s.caps.filter) return s.skip("filter.supported is false");
    const f = s.requireFixtures() orelse return;
    const p = s.fixturePrefix();
    const alice = f[0].user_name;
    const bob = f[1].user_name;
    const carol = f[2].user_name;

    const Case = struct { []const u8, i64, []const u8, check.Level };
    const cases = [_]Case{
        // Attribute operators.
        .{ s.fmt("userName eq \"{s}\"", .{alice}), 1, "eq matches exactly one User", .must },
        .{ s.fmt("userName sw \"{s}\" and userName ne \"{s}\"", .{ p, alice }), 2, "ne excludes the value", .must },
        .{ s.fmt("userName co \"{s}\" and userName co \"-bob\"", .{p}), 1, "co matches a substring", .must },
        .{ s.fmt("userName sw \"{s}\"", .{p}), 3, "sw matches a prefix", .must },
        .{ s.fmt("userName sw \"{s}\" and userName ew \"-carol\"", .{p}), 1, "ew matches a suffix", .must },
        .{ s.fmt("userName sw \"{s}\" and emails pr", .{p}), 3, "pr matches present attributes", .must },
        .{ s.fmt("userName sw \"{s}\" and title pr", .{p}), 0, "pr does not match absent attributes", .must },
        .{ s.fmt("userName sw \"{s}\" and name pr", .{p}), 3, "pr matches a complex attribute with a value", .must },
        .{ s.fmt("userName sw \"{s}\" and userName gt \"{s}\"", .{ p, alice }), 2, "gt compares strings lexicographically", .must },
        .{ s.fmt("userName sw \"{s}\" and userName ge \"{s}\"", .{ p, bob }), 2, "ge includes the value", .must },
        .{ s.fmt("userName sw \"{s}\" and userName lt \"{s}\"", .{ p, bob }), 1, "lt excludes the value", .must },
        .{ s.fmt("userName sw \"{s}\" and userName le \"{s}\"", .{ p, bob }), 2, "le includes the value", .must },
        .{ s.fmt("userName sw \"{s}\" and meta.created gt \"2000-01-01T00:00:00Z\"", .{p}), 3, "gt compares dateTimes", .must },
        .{ s.fmt("userName sw \"{s}\" and meta.lastModified lt \"2000-01-01T00:00:00Z\"", .{p}), 0, "lt compares dateTimes", .must },
        .{ s.fmt("userName sw \"{s}\" and meta.created gt \"2000-01-01T05:00:00+05:00\"", .{p}), 3, "dateTimes with a time zone offset compare chronologically", .must },
        .{ s.fmt("userName sw \"{s}\" and active eq true", .{p}), 2, "eq compares booleans", .must },
        .{ s.fmt("userName sw \"{s}\" and active eq false", .{p}), 1, "eq false matches inactive Users", .must },
        .{ s.fmt("userName eq \"{s}-nobody\"", .{p}), 0, "no match returns 200 with totalResults 0", .must },
        .{ s.fmt("userName eq \"{s}\\\"quote\"", .{p}), 0, "string values accept JSON escapes", .must },
        // RFC 7643 §2.5: null and unassigned are equivalent; bob has no nickName.
        .{ s.fmt("userName sw \"{s}\" and nickName eq null", .{p}), 1, "eq null matches unassigned attributes", .should },
        .{ s.fmt("userName sw \"{s}\" and nickName ne null", .{p}), 2, "ne null matches assigned attributes", .should },

        // Case rules.
        .{ s.fmt("userName eq \"{s}\"", .{upper(s, alice)}), 1, "eq ignores case for caseExact false attributes", .must },
        .{ s.fmt("userName sw \"{s}\"", .{upper(s, p)}), 3, "sw ignores case for caseExact false attributes", .must },
        .{ s.fmt("userName sw \"{s}\" and userName co \"-BOB\"", .{p}), 1, "co ignores case for caseExact false attributes", .must },
        .{ s.fmt("USERNAME eq \"{s}\"", .{alice}), 1, "attribute names are case-insensitive", .must },
        .{ s.fmt("userName EQ \"{s}\"", .{alice}), 1, "operators are case-insensitive", .must },
        .{ s.fmt("userName sw \"{s}\" AND userName ew \"-bob\"", .{p}), 1, "logical operators are case-insensitive", .must },
        .{ s.fmt("externalId eq \"{s}\"", .{f[0].external_id}), 1, "eq on externalId", .must },
        .{ s.fmt("externalId eq \"{s}\"", .{upper(s, f[0].external_id)}), 0, "eq respects caseExact for externalId", .must },
        .{ s.fmt("id eq \"{s}\"", .{f[1].id}), 1, "eq on id", .must },

        // Logical operators, precedence and grouping.
        .{ s.fmt("userName eq \"{s}\" or userName eq \"{s}\"", .{ alice, bob }), 2, "or matches either side", .must },
        .{ s.fmt("userName sw \"{s}\" and not (userName eq \"{s}\")", .{ p, alice }), 2, "not negates a grouped expression", .must },
        .{ s.fmt("userName eq \"{s}\" or userName eq \"{s}\" and userName eq \"{s}\"", .{ alice, bob, carol }), 1, "and binds tighter than or", .must },
        .{ s.fmt("(userName eq \"{s}\" or userName eq \"{s}\") and userName eq \"{s}\"", .{ alice, bob, carol }), 0, "parentheses override precedence", .must },
        .{ s.fmt("userName sw \"{s}\" and (name.givenName eq \"Alpha\" or (name.givenName eq \"Bravo\" and active eq false))", .{p}), 2, "nested groups", .must },

        // Attribute paths.
        .{ s.fmt("userName sw \"{s}\" and name.givenName eq \"Alpha\"", .{p}), 1, "sub-attribute of a complex attribute", .must },
        .{ s.fmt("userName sw \"{s}\" and emails.type eq \"work\"", .{p}), 3, "sub-attribute of a multi-valued attribute", .must },
        .{ s.fmt("userName sw \"{s}\" and emails[type eq \"work\" and value co \"@example.com\"]", .{p}), 3, "value path filter with and", .must },
        .{ s.fmt("userName sw \"{s}\" and emails[value sw \"a.\"]", .{p}), 1, "value path filter selects by value", .must },
        .{ s.fmt("userName sw \"{s}\" and not (emails[type eq \"home\"])", .{p}), 3, "not with a value path", .should },
        .{ s.fmt("{s}:userName eq \"{s}\"", .{ urn.user, alice }), 1, "URN-qualified attribute names (RFC 7644 §3.10)", .must },
        .{ s.fmt("userName sw \"{s}\" and meta.resourceType eq \"User\"", .{p}), 3, "filter on meta.resourceType", .should },
        .{ s.fmt("userName sw \"{s}\" and emails co \"a.{s}\"", .{ p, p }), 1, "a multi-valued attribute without a sub-attribute compares value", .should },
    };
    for (cases) |c| s.expectCount(ref, c[3], c[0], c[1], c[2]);

    // ids are caseExact (RFC 7643 §3.1): only meaningful if the id has letters.
    const id_upper = upper(s, f[1].id);
    if (!std.mem.eql(u8, id_upper, f[1].id)) {
        s.expectCount(ref, .must, s.fmt("id eq \"{s}\"", .{id_upper}), 0, "eq respects caseExact for id");
    }

    const invalid = [_]struct { []const u8, []const u8 }{
        .{ "userName eq", "a comparison without a value" },
        .{ "userName xx \"a\"", "an unknown operator" },
        .{ "(userName eq \"a\"", "unbalanced parentheses" },
        .{ "userName eq \"a\" and", "a dangling logical operator" },
        .{ "active gt true", "gt on a boolean" },
        .{ "x509Certificates.value gt \"YQ==\"", "gt on a binary attribute" },
        .{ "emails[type eq \"work\"", "an unterminated value path" },
    };
    for (invalid) |c| {
        if (s.send(.GET, s.fmt("{s}?filter={s}", .{ s.users_endpoint, s.escape(c[0]) }), .{})) |res| {
            s.expectError(.must, ref, res, .bad_request, "invalidFilter", s.fmt("{s} returns 400 invalidFilter", .{c[1]}));
        }
    }
}

fn upper(s: *Suite, v: []const u8) []const u8 {
    return std.ascii.allocUpperString(s.arena, v) catch v;
}
