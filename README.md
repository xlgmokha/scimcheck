# scimcheck

A command line tool, written in Zig, that checks whether a SCIM 2.0 service
provider follows [RFC 7643][7643] (schema) and [RFC 7644][7644] (protocol),
and lets you manage its resources.

```
$ scimcheck --url http://localhost:8080/scim/v2 --token secret check

Discovery (RFC 7644 §4, RFC 7643 §5-7)
  PASS  GET /ServiceProviderConfig returns 200 [RFC7644 §4]
  PASS  schema urn:ietf:params:scim:schemas:core:2.0:User attribute definitions are well formed [RFC7643 §7]
  ...
Sorting (RFC 7644 §3.4.2.3)
  PASS  sortBy a sub-attribute (name.givenName) [RFC7644 §3.4.2.3]
  FAIL  sortBy a multi-valued attribute uses the primary value [RFC7644 §3.4.2.3]
        got HTTP 400: {"schemas":["urn:ietf:params:scim:api:messages:2.0:Error"],"scimType":"invalidValue",...}
...
449 passed, 1 failed, 11 warnings, 6 info, 1 skipped
```

## Build

Requires Zig 0.16.0 and has no other dependencies. It uses only the standard
library: `std.http.Client` for HTTP and TLS, and `std.json` for JSON.

```
zig build                 # builds zig-out/bin/scimcheck
zig build test            # unit tests
zig build fmt             # format the source
zig build lint            # fail if anything is unformatted
zig build ci              # lint + tests + build, exactly what CI runs
zig build run -- --help
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl   # static binary
```

## Usage

Set the base URL and token with flags or environment variables:

```
export SCIM_URL=https://example.com/scim/v2
export SCIM_TOKEN=...
```

### Conformance checks

```
scimcheck check                        # every section
scimcheck check --only filter,patch    # some sections
scimcheck check --keep                 # keep the test resources
scimcheck -v check                     # print every HTTP exchange to stderr
```

Every check is graded by the RFC 2119 keyword behind it:

| Result | Meaning |
|--------|---------|
| `FAIL` | a MUST / SHALL / REQUIRED is violated; the exit status becomes 1 |
| `WARN` | a SHOULD / RECOMMENDED is not followed |
| `INFO` | an optional (MAY) feature is not supported |
| `SKIP` | the check cannot run, e.g. the feature is disabled in `/ServiceProviderConfig` |

The exit status is 1 if any MUST check fails, which makes `check` usable in CI.
[COVERAGE.md](COVERAGE.md) maps every section of RFC 7643 and RFC 7644 to the
checks that verify it, and lists what cannot be tested from outside a server.
Before it runs anything else, `check` reads `/ServiceProviderConfig` and
`/ResourceTypes`. It skips features the server says it does not support and
uses the endpoints the server advertises.

Each run creates its own resources, named `scimcheck-<run id>-...`, and
deletes them at the end.

| Section    | What it verifies |
|------------|------------------|
| discovery  | `/ServiceProviderConfig`, `/ResourceTypes` and `/Schemas` shape; required feature limits; authentication scheme types; every attribute definition against RFC 7643 §7; ResourceType ↔ Schema references; single-item and unknown lookups; 403 for filters |
| auth       | TLS; 401 without credentials, with an invalid token, or with another scheme; `WWW-Authenticate` and RFC 6750 error codes |
| errors     | 404 for GET/PUT/PATCH/DELETE of unknown resources; 400 for malformed JSON, missing required attributes, missing or unknown `schemas`, wrong types, binary values that are not base64; 405 + `Allow`; `/Me`; 413; Error schema and `scimType` values |
| users      | create/read/replace/delete, `Location` / `Content-Location` / `meta.*`, 409 `uniqueness` on POST, PUT and PATCH (case-insensitive), reuse of a deleted userName, readOnly input ignored, case-insensitive attribute names, both `Accept` media types, `application/json` requests, one primary value, `null` and `[]` as unassigned, every published core attribute stored, PUT clearing omitted attributes |
| extensions | the enterprise extension: storage, `schemas`, filtering, sorting, projection, PATCH by URN path, removal by PUT |
| attributes | `attributes` / `excludedAttributes` on GET, list, POST, PUT and PATCH; sub-attributes, URN-qualified names, `returned: always / never` |
| filter     | every operator (`eq ne co sw ew pr gt ge lt le`), `and`/`or`/`not`, precedence and grouping, value paths, sub-attribute and URN paths, booleans, dateTimes with time zones, `null`, `caseExact`, and seven kinds of invalid filters |
| search     | `POST /.search` with filter, attributes, paging and sorting; root queries |
| pagination | `startIndex`, `count`, `itemsPerPage`, `totalResults`, required ListResponse attributes, out-of-range values, `maxResults` exceeded with throwaway Users, a full page walk |
| sort       | `sortBy` on attributes, sub-attributes, multi-valued attributes by primary value, URN names; `sortOrder`; where resources without a value go; sorting with paging |
| patch      | add/replace/remove with and without paths, value filters and sub-attributes, multi-valued and primary rules, no-op adds keeping `meta.lastModified`, ordering, atomicity, and every error code |
| etag       | ETag syntax and stability, `meta.version`, `If-None-Match` 304, `If-Match` 412 on PUT/PATCH/DELETE, `If-Match: *` |
| groups     | membership, member `type` and `$ref`, nested groups, member filters, PATCH add/remove/replace members, immutable members, PUT, `User.groups`, referential integrity |
| bulk       | POST/PUT/PATCH/DELETE operations, bulkId and circular references, `failOnErrors` and error responses, `maxOperations` and `maxPayloadSize` → 413, or 501 when unsupported |

### Managing resources

Resources are addressed by **type name and id**. The type can be the name
from `scimcheck types` (`User`), its endpoint (`Users`, `/scim/v2/Users`), or
any case of either. The tool looks the name up in `/ResourceTypes`, so custom
resource types work the same way as User and Group. A literal path such as
`Users/2819c223` or `Schemas/urn:...` is sent as is.

#### Discover what the server has

```
$ scimcheck types
NAME   ENDPOINT         SCHEMA                                       EXTENSIONS
User   /scim/v2/Users   urn:ietf:params:scim:schemas:core:2.0:User   urn:ietf:params:scim:schemas:extension:enterprise:2.0:User
Group  /scim/v2/Groups  urn:ietf:params:scim:schemas:core:2.0:Group

scimcheck get ServiceProviderConfig     # supported features
scimcheck get Schemas                   # attribute definitions
```

#### List

```
$ scimcheck list -o table               # every resource of every type, all pages
TYPE   ID                                    NAME
User   01a0d724-e711-7d80-8a85-8ab628d24f63  amy
User   01a0d724-e71e-7111-9f9a-f2a590ab57b8  ben
Group  01a0d71e-cd1c-7900-ba32-fac3a277eed6  Admins

scimcheck list User                     # one page, the raw ListResponse
scimcheck list User --all               # every page, one resource per line
scimcheck list User --all --count 500   # --count is the page size with --all
scimcheck list Group --filter 'displayName sw "eng"' --sort-by displayName -o table
scimcheck search User --filter 'emails[type eq "work"]' --all   # POST /Users/.search
scimcheck search --filter 'meta.lastModified gt "2026-01-01T00:00:00Z"'   # POST /.search across all types
```

`--all` follows `startIndex` until `totalResults` is reached. `list` without a
type implies `--all` across every type from `/ResourceTypes`. It also adds
`meta.resourceType` to any resource that is missing it, so output that mixes
types stays unambiguous.

#### Create, read, update, delete

```
scimcheck create User --file bjensen.json
echo '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:Group"],"displayName":"Admins"}' | scimcheck create Group

scimcheck get User 2819c223
scimcheck get User 2819c223 --attributes userName,emails

scimcheck replace User 2819c223 --file bjensen.json --if-match 'W/"3694e05e9dff590"'

scimcheck patch User 2819c223 --op replace --path active --value false
scimcheck patch Group e9e30dba --op add --path members --value '[{"value":"2819c223"}]'
scimcheck patch Group e9e30dba --op remove --path 'members[value eq "2819c223"]'
scimcheck patch User 2819c223 --file ops.json          # a full PatchOp document

scimcheck delete User 2819c223
```

Request bodies come from `--data`, `--file` (`-` for stdin), or stdin.

#### Output

| `-o`    | Prints | Default for |
|---------|--------|-------------|
| `json`  | pretty JSON: the response, or one array for `--all` | single requests |
| `jsonl` | one compact resource per line | `--all`, `list` with no type |
| `table` | aligned `TYPE`, `ID`, `NAME` columns | `types` |
| `ids`   | one id per line | |

Data goes to stdout. The status line, `ETag`, `Location` and error bodies go to
stderr. The exit status is 0 on success, 1 for an HTTP error or an
unreachable server, and 2 for a usage error. The formats compose with other
tools:

```
scimcheck list User --filter 'active eq false' --all -o ids |
  xargs -n1 scimcheck delete User                      # delete every inactive user
scimcheck list --all | jq -s 'group_by(.meta.resourceType) | map({(.[0].meta.resourceType): length}) | add'
ID=$(scimcheck create User --file u.json -o ids)
```

## How it is built

This is the part to read if you want to build something similar or add checks.

```
src/
  main.zig      entry point: builds the client and dispatches
  args.zig      flags and help text
  commands.zig  resource commands, type-name resolution, paging
  output.zig    json / jsonl / table / ids rendering
  Client.zig    SCIM-flavoured wrapper around std.http.Client
  json.zig      case-insensitive lookups over std.json.Value
  check.zig     the conformance suite
```

### 1. An HTTP client that keeps the headers SCIM cares about

`std.http.Client.fetch` only returns the status, and SCIM checks need
`Location`, `ETag`, `Content-Type` and `WWW-Authenticate`. So `Client.send`
uses the lower level `request` → `sendBodyComplete`/`sendBodiless` →
`receiveHead` sequence, copies those headers into an arena, and then reads
the body. The copy has to happen first because the header slices point into
the connection buffer and are invalidated once the body is read.

A few Zig 0.16 details are worth knowing:

- `pub fn main(init: std.process.Init)` receives the allocators, the `Io`
  instance, the arguments and the environment. Everything that does I/O takes
  that `io`.
- Everything a run allocates goes into one arena that is freed when the
  process exits. That fits a short-lived CLI, and it means the check code does
  not have to deal with freeing memory.
- 204 and 304 responses have no body. Calling `response.reader()` on one, or
  letting `Request.deinit` drain it, reads until the connection closes, which
  hangs on a kept-alive connection. `Client.send` skips the body for those
  statuses and marks the reader state `.ready`.
- Connections are direct. `HTTP(S)_PROXY` is not used, because
  `std.http.Client.initDefaultProxies` ignores `NO_PROXY` and would route
  `localhost` through the proxy.

### 2. JSON without schemas

SCIM resources are open ended: extensions, custom attributes, and attribute
names that are case-insensitive (RFC 7643 §2.1). So the tool parses bodies into
`std.json.Value` rather than typed structs. `json.zig` supplies the small
helpers the checks use: `field`, `path("meta.location")`, `hasSchema`, and
`findBy(emails, "type", "work")`.

Request bodies are built with `std.fmt` and `std.json.fmt(value, .{})`, which
escapes the interpolated strings.

### 3. A suite where each check cites the RFC

Every assertion goes through a single `Suite.check(level, ref, ok, what, detail)`:

```zig
_ = s.check(.must, "RFC7644 §3.3", res.location != null,
    "201 response includes a Location header", null);
```

- `level` is `.must`, `.should` or `.may`, matching the RFC 2119 keyword in
  the spec. A failed `.must` check fails the run; the others print `WARN` or `INFO`.
- `ref` is the section the check verifies, printed on every line, so a
  failure tells you which part of the RFC to read.
- Helpers built on top of it (`expectStatus`, `expectError`, `expectList`,
  `expectCount`, `expectPatch`) keep each section short and readable.

`src/check.zig` holds this machinery. Each section is a `run(*Suite)`
function in its own file under `src/checks/`, listed in the `Section` enum.
Shared fixtures are created once, on demand, by `requireFixtures`: three
users that sort alice < bob < carol by userName and by first email but
bob < carol < alice by `name.givenName` and by primary email, so every
`sortBy` is distinguishable. Their userNames start with
`scimcheck-<run id>-fixture-`, which throwaway users must not reuse. Every created resource is recorded and deleted
in reverse order at the end, so groups are deleted before their members.

### 4. Adding a check

Find the RFC requirement, decide whether it is a MUST or a SHOULD, and add it
to the matching file in `src/checks/`:

```zig
if (s.send(.GET, s.fmt("{s}?attributes=name.givenName", .{f[0].path}), .{})) |res| {
    if (s.expectStatus(.must, ref, res, .ok, "GET with attributes=name.givenName returns 200")) {
        const body = s.json(res);
        _ = s.check(.must, ref, j.path(body, "name.givenName") != null and j.path(body, "name.familyName") == null,
            "sub-attribute selection omits sibling sub-attributes", res.body);
    }
}
```

For a new section, add a file with a `pub fn run(s: *Suite) void` and a
variant to `Section` in `src/check.zig` with its title and file.

`json.path` understands RFC 7644 §3.10 notation, so
`j.path(body, "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User:manager.value")`
reads extension attributes.

### 5. Testing against a real server

The CI workflow builds the [scim-go][scim-go] example server and runs
`scimcheck check` against it. That step fails only if scimcheck crashes or
reports a transport error, not when scim-go fails a conformance check, so a
gap in the server doesn't block changes to the tool. Locally:

```
go install github.com/supabase-community/scim-go/cmd/server@main
SCIM_BEARER_TOKEN=secret server &
zig build run -- --url http://localhost:8080/scim/v2 --token secret check
```

[7643]: https://datatracker.ietf.org/doc/html/rfc7643
[7644]: https://datatracker.ietf.org/doc/html/rfc7644
[scim-go]: https://github.com/supabase-community/scim-go
