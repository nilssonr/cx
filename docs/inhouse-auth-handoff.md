# Handoff: a self-hosted, minimal OAuth2/OIDC issuer for cx

> Paste this as the opening prompt for a fresh working session. It is a **design
> brief**, not an implementation order — the first deliverable is a design doc,
> not code. Auth is security-critical; scope it deliberately.

## The ask

Design (then, once approved, build) a **minimal in-house authentication path** for
cx: cx issues and verifies its own signed tokens against a **local user +
credential store**, so a deployment needs no third-party identity platform to log
in. Keep the existing **OIDC token-verification seam** so enterprise customers can
instead federate to their own IdP (AD / Entra / Okta / Zitadel). Do **not**
force-choose between "our IdP" and "their IdP" — ship a local default, allow
federation.

## Why (the motivation that drives this)

cx ships **on-prem to customer sites we do not operate and cannot reach**. Today
authentication depends on an external OIDC provider (Zitadel in dev). For our
deployment model that is a liability:

- When auth breaks, the contact center is **down**, and auth lives in a separate
  system (Go + its own datastore) we cannot debug on a customer site — no live
  logging, no `recon`, no remote shell, no "ship a debug build."
- cx is one BEAM: hot code loading, tracing, `logger`, remote shell. An in-house
  auth path inherits **all** of that observability; a bolted-on IdP inherits none.
- cx **already owns the identity domain** — users, roles, tenants, and permissions
  live in Mnesia (`cx_user`, `cx_role`, `cx_permission`, tenant keying). The
  external IdP is largely **redundant**: it duplicates the user identity and we
  link the two by `sub`. The only things it does that cx does not are (a) verify a
  credential at login and (b) mint a signed token.
- `cx_auth` is already cleanly abstracted as "verify a token → subject + tenant +
  permissions." Adding an **issuer** is additive, not a rewrite. In fact
  `cx_auth_test` already mints real signed JWTs against a keypair — the issuing
  surface is small and half-prototyped in test code.

This also resolves an open product wart: cross-tenant platform admin currently
rides an **`X-Tenant-Id` request header** (unsigned side-channel). If cx issues its
own tokens, the target tenant becomes a **signed claim** (act-as-tenant), and the
header + `cx_handler:scope_tenant_header/2` go away — tenant selection moves into
the signed identity where it belongs.

## Scope of "minimal" (in)

- **Credential store**: passwords for local users (extend `cx_user` or add a
  `cx_credential` table, tenant-keyed like everything else). Hash with a **vetted
  library** (argon2id preferred; bcrypt acceptable) — never hand-rolled.
- **Login endpoint**: verify credential → issue a **short-lived** signed JWT
  (`jose`, already a dep) carrying `sub`, tenant (org), and the permission/role
  claims cx already derives. Refresh-token or re-login flow (keep simple).
- **Signing keys**: generate + rotate an RSA/EC key; cx exposes its **own JWKS** so
  the existing verify path (`cx_auth_jwt` / `cx_jwks_cache`) consumes cx-issued
  tokens exactly like external ones. `key_source` already selects the verifier.
- **Act-as-tenant claim**: honored only for platform admins
  (`platform_admin_subjects` / the `*` wildcard); replaces the `X-Tenant-Id` header.
- **Federation preserved**: the OIDC verify path stays; a deployment configures
  either the built-in issuer or an external IdP (or both).

## Out of scope / risks / do-not-cut-corners (out)

- **Not an "auth-disabled" mode** — the project forbids one. This is *real* auth:
  real JWTs, real verification, real key management.
- Security-critical edges that MUST be designed, not winged: password hashing
  choice, **login rate-limiting / lockout**, token expiry + refresh + revocation,
  **signing-key rotation**, clock skew. Threat-model these.
- **MFA** and **self-service password reset**: likely v1.1; scope explicitly, do
  not half-build.
- **Keep OIDC federation.** Enterprise on-prem CC customers frequently already run
  AD/Entra/Okta and will want cx to federate rather than maintain a second user
  store. A local-only IdP that cannot federate will bite us in the biggest accounts.
- Do not break: WebSocket **in-band first-frame auth** (`cx_handler_socket`), the
  `#auth_context{}` shape, or the "authz in the domain layer, never in transports"
  rule.

## Codebase constraints to respect

- Definition of Done gates (all must pass): `rebar3 compile` (zero warnings), `fmt
  --check`, `eunit`, `ct`, `elp eqwalize-all` (NO ERRORS), `elp lint
  --diagnostic-ignore W0051`. See root `CLAUDE.md`.
- eqWAlizer discipline; the naming law (full-word symbols; `#cx_*` = persisted
  Mnesia table only); every Mnesia key is `{TenantId, Id}`; new tables in
  `cx_db:table_specs/0`.
- `cx` does not (today) issue tokens — that is exactly the boundary this work moves.

## Files to read first

- `apps/cx_auth/src/cx_auth.erl` — Bearer strip → verify → claims.
- `apps/cx_auth/src/cx_auth_jwt.erl` — JWT verification (jose/JWKS).
- `apps/cx_auth/src/cx_auth_claims.erl` — claims → `#auth_context{}`; tenant claim,
  `platform_admin_subjects`, role → permission derivation.
- `apps/cx_auth/src/cx_jwks_cache.erl` — key source, HTTP JWKS fetch, `http_options`.
- `apps/cx_auth/test/` `cx_auth_test` — already mints signed JWTs against a keypair
  (the issuer prototype).
- `apps/cx_core/src/cx_user.erl`, `cx_permission.erl`, `cx_authz.erl` — the identity
  domain cx already owns.
- `apps/cx_api_rest/src/cx_rest_auth_middleware.erl`, `cx_handler.erl`
  (`scope_tenant_header/2`) — where the header-based tenant override lives today and
  what the act-as-tenant claim would replace.
- `config/sys.config` — current `cx_auth` config (`issuer`, `key_source`,
  `tenant_claim`, `platform_admin_subjects`).

## First deliverable

A short **design doc** (not code) covering: the token model (claims, signing alg,
lifetime, refresh, revocation), signing-key generation + rotation + JWKS exposure,
the credential store + hashing choice, the login/refresh lifecycle, how the
built-in issuer and the federation path share the verify seam, and the
threat-model of the security-critical edges above. Pressure-test that before any
implementation.
