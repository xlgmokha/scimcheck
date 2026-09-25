# scimcheck

A command line tool, written in Zig, that checks whether a SCIM 2.0 service
provider follows [RFC 7643][7643] (schema) and [RFC 7644][7644] (protocol),
and lets you manage its resources.

```
$ scimcheck --url http://localhost:8080/scim/v2 --token secret check

Discovery (RFC 7644 §4)
  PASS  GET /ServiceProviderConfig returns 200 [RFC7644 §4]
  PASS  Content-Type is application/scim+json [RFC7644 §3.1]
  ...
Filtering (RFC 7644 §3.4.2.2)
  PASS  eq on userName is case-insensitive (caseExact false) [RFC7644 §3.4.2.2]
  WARN  POST /Users/.search returns 200 [RFC7644 §3.4.3]
        got HTTP 405: {"schemas":["urn:ietf:params:scim:api:messages:2.0:Error"],...}
...
174 passed, 0 failed, 4 warnings, 0 skipped
```

## Build

Requires Zig 0.16.0 and has no other dependencies. It uses only the standard
library: `std.http.Client` for HTTP and TLS, and `std.json` for JSON.

```
zig build                 # builds zig-out/bin/scimcheck
zig build test            # unit tests
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

The exit status is 1 if any MUST check fails, which makes `check` usable in CI.
A failed SHOULD check prints `WARN` and does not change the exit status.
Before it runs anything else, `check` reads `/ServiceProviderConfig` and
`/ResourceTypes`. It skips features the server says it does not support and
uses the endpoints the server advertises.

Each run creates its own resources, named `scimcheck-<run id>-...`, and
deletes them at the end.

| Section      | What it verifies |
|--------------|------------------|
| discovery    | `/ServiceProviderConfig`, `/ResourceTypes`, `/Schemas` shape; 403 for filters on discovery endpoints |
| auth         | 401 plus `WWW-Authenticate` without credentials |
| errors       | Error schema, `status` as a string, `scimType` for 404/400 cases |
| users        | POST/GET/PUT/DELETE, 201 + `Location`, `meta.*`, 409 `uniqueness`, password never returned |
| attributes   | `attributes` / `excludedAttributes`, `id` always returned |
| filter       | `eq`, `sw`, `co`, `ew`, `pr`, `gt`, `and`/`or`/`not`, value paths, case rules, 400 `invalidFilter`, `POST /.search` |
| pagination   | `startIndex`, `count`, `count=0`, out of range values |
| sort         | `sortBy`, `sortOrder` |
| patch        | add/replace/remove with and without paths and value filters, `noTarget`, `invalidPath`, `mutability` |
| etag         | `ETag`/`meta.version`, `If-None-Match` 304, `If-Match` 412 |
| groups       | membership, PATCH add/remove members, `User.groups` |
| bulk         | a bulk create, or 501 when bulk is unsupported |

### Managing resources

Resource commands print the status line and headers to stderr and the
pretty-printed JSON body to stdout, so you can pipe the output into `jq`.

```
scimcheck get ServiceProviderConfig
scimcheck get Users/2819c223 --attributes userName,emails
scimcheck list Users --filter 'userName sw "b"' --sort-by userName --count 10
scimcheck search Groups --filter 'displayName eq "Admins"'      # POST /Groups/.search

scimcheck create Users --file user.json
echo '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:User"],"userName":"bjensen"}' | scimcheck create Users
scimcheck replace Users/2819c223 --file user.json --if-match 'W/"3694e05e9dff590"'
scimcheck patch Users/2819c223 --op replace --path active --value false
scimcheck patch Groups/e9e30dba --file patch.json
scimcheck delete Users/2819c223
```

## How it is built

This is the part to read if you want to build something similar or add checks.

```
src/
  main.zig     argument parsing and the resource commands
  Client.zig   SCIM-flavoured wrapper around std.http.Client
  json.zig     case-insensitive lookups over std.json.Value
  check.zig    the conformance suite
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

- `level` is `.must` or `.should`, matching the RFC 2119 keyword in the spec.
  A failed `.must` check fails the run; a failed `.should` check prints a warning.
- `ref` is the section the check verifies, printed on every line, so a
  failure tells you which part of the RFC to read.
- Helpers built on top of it (`expectStatus`, `expectError`, `expectList`,
  `expectCount`, `expectPatch`) keep each section short and readable.

Sections are plain functions registered in `Suite.run`. Shared fixtures (three
users named so that they sort alice < bob < carol) are created once, on
demand, by `requireFixtures`. Every created resource is recorded and deleted
in reverse order at the end, so groups are deleted before their members.

### 4. Adding a check

Find the RFC requirement, decide whether it is a MUST or a SHOULD, and add it
to the matching section in `src/check.zig`:

```zig
if (s.send(.GET, s.fmt("{s}?attributes=name.givenName", .{f[0].path}), .{})) |res| {
    if (s.expectStatus(.must, ref, res, .ok, "GET with attributes=name.givenName returns 200")) {
        const body = res.json(s.arena);
        _ = s.check(.must, ref, j.path(body, "name.givenName") != null and j.path(body, "name.familyName") == null,
            "sub-attribute selection omits sibling sub-attributes", res.body);
    }
}
```

For a new section, add a variant to `Section` with a title and register its
function in `Suite.run`.

### 5. Testing against a real server

The CI workflow builds the [scim-go][scim-go] example server and runs
`scimcheck check` against it. Locally:

```
go install github.com/supabase-community/scim-go/cmd/server@main
SCIM_BEARER_TOKEN=secret server &
zig build run -- --url http://localhost:8080/scim/v2 --token secret check
```

[7643]: https://datatracker.ietf.org/doc/html/rfc7643
[7644]: https://datatracker.ietf.org/doc/html/rfc7644
[scim-go]: https://github.com/supabase-community/scim-go
