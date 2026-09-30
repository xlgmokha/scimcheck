# RFC coverage

This file maps each section of [RFC 7644][7644] (protocol) and
[RFC 7643][7643] (schema) to the `scimcheck check` sections that verify it.
Section names are the values accepted by `--only`. **Partial** means the
testable requirements are covered but some behaviour needs server-side access
or configuration a client cannot see.

## RFC 7644: protocol

| § | Topic | Checked by | Coverage |
|---|-------|------------|----------|
| 2 | Authentication and authorization | auth | 401 without credentials, with an invalid token, with another scheme, with an empty bearer token; `WWW-Authenticate`; RFC 6750 `invalid_token`. Authorization policy (what a token may see) is server-specific. |
| 3.1 | Media type | users, discovery, groups | `application/scim+json` on responses; `application/json` accepted on requests; `Accept` with either media type |
| 3.2 | Endpoints and methods | errors | unknown endpoints 404, unsupported methods 405 + `Allow` |
| 3.3 | Creating resources | users, groups, extensions, errors | 201, `Location`, `meta`, response body, 409 `uniqueness`, 400 for invalid input |
| 3.3.1 | Resource types | discovery | endpoints are taken from `/ResourceTypes` |
| 3.4.1 | Retrieving a known resource | users, groups, errors | 200 with the resource, 404 for unknown and deleted resources |
| 3.4.2.1 | Query endpoints | search | resource-type queries; root queries reported as INFO (MAY) |
| 3.4.2.2 | Filtering | filter, groups, extensions | all 10 operators, `and`/`or`/`not`, precedence, grouping, value paths, sub-attribute and URN paths, booleans, dateTimes (including time zone offsets), `null` as unassigned, `caseExact` for every string operator, ordering operators on boolean and binary attributes rejected, case-insensitive names and operators, `invalidFilter` |
| 3.4.2.3 | Sorting | sort, extensions, search | ascending default, `sortOrder`, sub-attributes, multi-valued attributes by their primary (not first) value, resources without a value last when ascending and first when descending, URN names, extension attributes, with paging |
| 3.4.2.4 | Pagination | pagination, search | `startIndex`/`count` defaults and bounds, `itemsPerPage`, `totalResults`, `Resources`, `startIndex` and `itemsPerPage` present on partial pages, `maxResults` (creating throwaway Users to exceed it when needed), a full page walk |
| 3.4.2.5 | Attributes on queries | attributes | `attributes` / `excludedAttributes` on lists |
| 3.4.3 | Querying with POST | search | filter, attributes, excludedAttributes, paging and sorting in a SearchRequest; root `/.search` as INFO |
| 3.5.1 | Replacing with PUT | users, groups, extensions, etag | replacement, readOnly `id` ignored, `meta` handling, omitted attributes cleared, required attributes enforced, 409 `uniqueness` |
| 3.5.2 | Modifying with PATCH | patch, groups, extensions, etag | atomicity, ordering, 200 vs 204, errors (`noTarget`, `invalidPath`, `mutability`, `invalidSyntax`, 409 `uniqueness`), primary handling, no-op adds keep `meta.lastModified` |
| 3.5.2.1 | add | patch, groups | with and without a path, single- and multi-valued targets, sub-attributes, value filters, duplicates |
| 3.5.2.2 | remove | patch, groups, extensions | attributes, sub-attributes (also through value filters), value filters, filters that match nothing, whole multi-valued attributes, missing path |
| 3.5.2.3 | replace | patch, groups, extensions | with and without a path, complex values, value filters, unmatched filters, adding absent attributes |
| 3.6 | Deleting | users, groups, etag | 204, then 404; omitted from queries; a deleted userName can be reused; groups do not delete members; reference cleanup as INFO |
| 3.7 | Bulk | bulk | **Partial.** POST, PUT, PATCH and DELETE operations with their `method`, `location` and `status`; bulkId references; `failOnErrors` and the error `response` of a failed operation; `maxOperations` and `maxPayloadSize` → 413; 501 when unsupported; circular bulkId references resolved or reported as 409. |
| 3.8 | Data formats | users, errors | JSON only; case-insensitive attribute names; malformed JSON → `invalidSyntax` |
| 3.9 | Response parameters | attributes | GET, list, POST, PUT and PATCH; `returned: always` and `never` |
| 3.10 | Attribute notation | attributes, filter, sort, extensions | URN-qualified core and extension attributes in all three |
| 3.11 | `/Me` | errors | **Partial.** 200, 308 or 501. `/Me` semantics need a token bound to a known user. |
| 3.12 | Errors | every section | Error schema, `status` as a string, the expected `scimType`, unknown `scimType` values; 400/401/403/404/405/409/412/413/501. `tooMany`, `sensitive` and `invalidVers` depend on server policy and are not triggered. |
| 3.13 | Protocol versioning | none | Not testable: there is no negotiable version. |
| 3.14 | Versioning with ETags | etag, users | ETag syntax, stability and change, `meta.version`, `If-None-Match` 304, `If-Match` 412 on PUT/PATCH/DELETE, `If-Match: *` |
| 4 | Discovery endpoints | discovery, auth | shape of all three endpoints, single-item and unknown lookups, 403 for filters, unauthenticated access as INFO |
| 5 | Internationalized strings | none | Not covered: PRECIS comparison rules are not exercised. |
| 6 | Multi-tenancy | none | Not testable from one tenant. |
| 7 | Security | auth | **Partial.** The service provider is reached over TLS (§7.2; skipped for loopback addresses). TLS versions, token handling and logging are not visible to a client. |

## RFC 7643: schema

| § | Topic | Checked by | Coverage |
|---|-------|------------|----------|
| 2.1 | Case-insensitive attribute names | users, attributes, filter, sort | request bodies, `attributes`, filters, `sortBy` |
| 2.2 | Attribute characteristics | users, patch, attributes, filter, groups, discovery | readOnly (`id`, `meta`, `groups`), writeOnly/never (`password`), `returned: always` (`id`), `required`, `uniqueness`, `caseExact`, immutable member values |
| 2.3 | Data types | users, errors, filter, patch | boolean, dateTime and reference values; wrong JSON types rejected; binary values that are not base64 rejected on POST and PATCH. **Partial:** decimal and integer attributes are not in the core schemas. |
| 2.4 | Multi-valued attributes | users, patch | at most one `primary`; setting a new primary clears the others |
| 2.5 | Unassigned and null values | users, filter | PUT clears omitted attributes; `null` and `[]` in a request leave an attribute unassigned; `eq null` and `ne null` in filters |
| 3 | Resources and `schemas` | users, errors, extensions | `schemas` required and known; extension URNs listed |
| 3.1 | Common attributes | users, filter | `id` assigned by the server and caseExact; `externalId` caseExact; `meta.resourceType/created/lastModified/location/version`; `Content-Location` |
| 3.3 | Extensions | extensions | storage, retrieval, filtering, sorting, projection, PATCH, removal |
| 4.1 | User | users, patch, filter | `userName`, `name`, `displayName`, `nickName`, `title`, `profileUrl`, `emails`, `phoneNumbers`, `active`, `password`, `groups`; every other §4.1 attribute the User schema publishes as writable is stored and returned |
| 4.2 | Group | groups, discovery | `displayName` required; members' `value`, `type` and `$ref`; membership changes; nested Groups as INFO |
| 4.3 | Enterprise User | extensions | `employeeNumber`, `department`, `costCenter`, `manager.value`, readOnly `manager.displayName` |
| 5 | ServiceProviderConfig | discovery | every feature flag, `maxResults`, bulk limits, authentication schemes |
| 6 | ResourceType | discovery | required attributes, `endpoint` relative to the base URL, `schemaExtensions`, and references into `/Schemas` |
| 7 | Schema definitions | discovery | every attribute definition: types, flags, `mutability`, `returned`, `uniqueness`, `subAttributes`, `referenceTypes`, no nested complex attributes |
| 8 | JSON examples | none | Not covered: the examples are documentation. scim-go checks them itself in `pkg/scimtest`. |

## Levels

Each check uses the level of the RFC 2119 keyword it is based on:
- `FAIL`: MUST, SHALL or REQUIRED.
- `WARN`: SHOULD or RECOMMENDED.
- `INFO`: MAY or OPTIONAL.

Where the RFC allows more than one outcome (for example 400 or silently
ignoring a readOnly `id`), the check accepts every allowed outcome.

[7643]: https://datatracker.ietf.org/doc/html/rfc7643
[7644]: https://datatracker.ietf.org/doc/html/rfc7644
