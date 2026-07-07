# In-house authentication & authorization — design

Status: **draft for pressure-test** (no code yet). Supersedes the "bespoke
`POST /login`" sketch in [`inhouse-auth-handoff.md`](./inhouse-auth-handoff.md);
that flow was effectively the OAuth Resource Owner Password Credentials grant,
which RFC 9700 §2.4 forbids ("MUST NOT be used"). This document designs cx as a
**standards-conformant OAuth 2.0 Authorization Server / OpenID Connect Provider**.

The guiding rule for this work: **every relevant MUST/SHALL and SHOULD is
honored, or explicitly deferred with a documented justification.** No shortcuts.
The conformance matrix (§13) is the audit surface for that claim and is built
from the RFC text directly, not from memory.

---

## 1. Scope

### In (v1)

- cx is the **OpenID Provider (OP)** for a deployment: it authenticates local
  users, mints its own signed tokens, and exposes a standard OP surface
  (discovery, JWKS, authorize, token, userinfo, revoke, introspect).
- **Grants:** `authorization_code` + PKCE, `refresh_token`, `client_credentials`.
  - `authorization_code`/`refresh_token` are fully built and exercised by the
    first-party **browser SPA** and **native mobile app** (both *public*
    clients).
  - `client_credentials` is implemented at `/token` so third-party integrators
    slot into the *same* endpoints later; v1 onboards no third-party clients and
    does not finalize their scope catalog.
- **Local credential store** (`cx_identity`) + password hashing.
- **Signing keys**: generated, rotated, exposed via JWKS; cx verifies its own
  tokens in-process.
- **Tenant selection** folded into the authorization interaction; the
  `X-Tenant-Id` header is **removed** and replaced by signed claims.
- **Provider session** (`cx_provider_session`) with **Remember-me** and a
  **tenant switcher** for multi-tenant users — silent (`prompt=none`)
  re-authorization so refresh-expiry, cold-start, and the second client do not
  re-prompt for a password (§9.4).
- **Login UI**: minimal server-rendered `/authorize` pages (login + tenant
  picker), functional and unbranded in this PR; theming deferred (D13).
- **No migration**: greenfield deployment. Zitadel was **dev-only, never used in
  production**, and is removed with this work (drop the docker-compose Zitadel +
  `allow_insecure_jwks` dev config once the built-in issuer is default).

### Out (v1) — explicitly deferred, seam kept open

- **Federation** (cx as a Relying Party to AD/Entra/Okta) — v2. The token-verify
  seam (`cx_auth_keys`, `iss`/`aud` checks) is preserved, not removed; v2 is the
  mirror role.
- **Third-party integrator onboarding + M2M scope catalog** — later; grant
  machinery present.
- **MFA**, **self-service password reset (forgot-password)** — v1.1. Credential
  model is shaped so these are additive (see §4).
- **Sender-constrained tokens (DPoP / mTLS)** — candidate deferral, decided
  per-SHOULD in §13.
- **Dynamic client registration (RFC 7591)** — not needed; clients are seeded or
  admin-registered.
- **Login-UI theming / branding / localization** — follow-up PRs (D13).
- **Immediate access-token revocation (denylist)** — v1.x (D12). The v1 cutoff
  levers are short token lifetime + refresh revocation + `force_stop_session`.

There is **no "auth disabled" mode**, per project charter. This is real auth.

---

## 2. Architectural position

```
                    ┌─────────────────────────────────────────┐
   SPA / mobile ───►│  /authorize  (login UI + tenant picker)  │
   (public client)  │  /token      (code→tokens, refresh, cc)  │  cx = OP
                    │  /userinfo /revoke /introspect           │
                    │  /.well-known/openid-configuration       │
                    │  /.well-known/jwks.json                  │
                    └───────────────┬─────────────────────────┘
                                    │ issues signed JWT (RS256)
                                    ▼
   every request ──► cx_auth (verify) ──► #auth_context{} ──► domain (authz)
                                    ▲
                                    └── v2: also verifies EXTERNAL OP tokens
                                        (federation; same seam)
```

The **verify half already exists and is clean** (`cx_auth` → `cx_auth_jwt` →
`cx_auth_claims`). This work adds the **issue half** and the credential/key/client
substrate under it. `#auth_context{}` and "authz in the domain layer, never in
transports" are unchanged.

---

## 3. Identity model

Two entities, different cardinalities, joined by `subject`:

```
cx_identity   (the PERSON — global, issuer-level)
  subject         stable global id (cx_id:new())          ← primary key
  email           login handle, GLOBALLY UNIQUE (indexed)
  password_hash   PHC string ($pbkdf2-sha512$...)
  status          active | disabled | locked
  failed_count    login-failure counter (lockout)
  locked_until    ms epoch | undefined
  created_at / updated_at
        │  subject  (1 : N)
        ▼
cx_user       (the MEMBERSHIP in one tenant — per-tenant)
  key = {TenantId, Id}
  subject         → the identity (already indexed today)
  name, email, role_ids, skills, routing_profile_id, status, ...
```

Why separate (each interesting case is an asymmetry):

- **One person, many tenants** → one `cx_identity`, several `cx_user` rows. One
  password; per-tenant roles/skills. This is the tenant-picker case.
- **Platform admin** = an identity with **zero** users (authenticates, belongs to
  no tenant, acts-as-tenant). Cannot be expressed if credentials live on
  `cx_user`.
- **Federated user (v2)** = a user with **zero** identity (its `subject` points at
  an external OP; no local password). `fetch_by_subject` resolves both the same.

The join is `subject ↔ subject`; a `subject` resolves to a *local identity* or
(v2) an *external OP*, and `cx_user` never needs to know which. **The verify path
is unchanged**: token carries `sub` + tenant; `cx_auth_claims:resolve_user`
still calls `cx_user:fetch_by_subject(TenantId, Sub)`.

**Global-unique email** is deliberate and correct: email is already a global
identifier; the same address in two tenants is the same human, and "one human,
one credential, pick your tenant" is the feature. Uniqueness is enforced in the
write transaction (Mnesia does not enforce unique secondary indexes), reusing the
`cx_user:write_checked/2` read-then-write pattern.

`cx_user.email` (tenant-facing contact/display) stays distinct from
`cx_identity.email` (login handle) — they usually match for local users but
diverge for federated ones, exactly as mature IdPs separate login handle from
profile email.

---

## 4. Credential store & password hashing

- **Algorithm: PBKDF2-HMAC-SHA512** via **`crypto:pbkdf2_hmac/5`** (built into
  OTP 29, OpenSSL-backed). **Zero new dependencies, native performance, FIPS-
  approved, not hand-rolled** (it iterates a vetted primitive; we invent no
  crypto). Iteration count per current OWASP guidance (≥210k; pinned in config,
  raisable without migration — see PHC storage below).
- **Not** memory-hard (unlike argon2id) — accepted tradeoff to avoid a NIF
  dependency. Memory-hardness is a swap-in later (§4, PHC seam).
- **Storage: self-describing PHC string** `$pbkdf2-sha512$i=210000$<salt>$<hash>`.
  Algorithm + params travel with each row, so raising cost or switching to
  argon2id later is a **module swap + lazy re-hash on next successful login** — no
  data migration.
- **Hashing behaviour**: a tiny `cx_password` behaviour (`hash/1`, `verify/2`)
  behind the PHC format; PBKDF2 is the only v1 backend.
- **Client secrets** (confidential clients, §5) are **high-entropy random**, so a
  single fast **SHA-256** is sufficient and standard — PBKDF2 is for human
  passwords only.
- **Comparison** is constant-time; unknown-email login still performs a dummy
  hash to equalize timing (enumeration resistance, §12).

MFA (v1.1) splits the *secret* out of the *person*: a future `cx_credential`
child table keyed by subject holds `{type=password|totp|passkey, ...}` and
`cx_identity` loses `password_hash`. Naming the person entity `cx_identity` (not
`cx_credential`) now is what keeps that a non-migration.

---

## 5. Client model

OAuth has **clients**; cx has never modelled them. New table `cx_oauth_client`,
keyed by **`client_id` (globally unique — OAuth requires it)**, carrying an
optional `tenant_id` field rather than a `{TenantId, Id}` key:

```
cx_oauth_client
  client_id       globally unique                         ← primary key
  tenant_id       undefined = first-party global;
                  set = third-party, scoped to that tenant
  client_type     public | confidential
  grant_types     [authorization_code | refresh_token | client_credentials]
  redirect_uris   exact-match set (public clients)
  scopes          allowed scope set
  secret_hash     SHA-256 (confidential only; undefined for public)
  status, created_at, updated_at
```

- **First-party (v1): SPA + mobile.** `client_type = public`, **no secret**, PKCE
  **required**, exact-match registered `redirect_uris` (mobile per RFC 8252:
  system browser + claimed-https/custom-scheme/loopback redirect, **no embedded
  webview**). Seeded like the bootstrap admin (§10).
- **Third-party (deferred): integrators.** `client_type = confidential`,
  `tenant_id` set, `client_credentials` only, hashed secret. Registered by a
  tenant admin via the admin API (no RFC 7591 dynamic registration in v1).

`client_id` global uniqueness keeps a single Mnesia key shape and satisfies
OAuth; the `tenant_id` *field* (not the key) scopes an integrator client. Cross-
tenant isolation holds: a client never reads another tenant's domain data — its
tenant association is enforced by the field + the token's tenant claim.

---

## 6. Token model

Four artifacts:

| Artifact | Format | Audience | Lifetime | Storage |
|---|---|---|---|---|
| **Access token** | JWT (RFC 9068, `typ: at+jwt`) | the cx API (`cx-api`) | ~10 min | stateless (self-verified) |
| **ID token** | JWT (OIDC Core) | the client (`aud = client_id`) | ~10 min | stateless |
| **Refresh token** | opaque handle | — | long, sliding | `cx_refresh_token` (stored, rotating, revocable) |
| **Authorization code** | opaque handle | — | ~60 s, single-use | `cx_authorization_code` (ram, cluster-replicated) |

### cx claim set (spelled-out names, per naming law)

`sub`, `iss`, `aud`, `exp`, `iat`, `nbf`, `jti` (RFC-registered, kept as-is), plus
cx claims:

- **`tenant_id`** — the tenant this token acts in (replaces the Zitadel org claim;
  set `tenant_claim` config to `<<"tenant_id">>`).
- **`act_as_tenant`** — platform-admin cross-tenant target. Minted **only** if the
  identity holds the capability; honored at verify **only** for `*` /
  `tenants:admin` holders (authorized at both ends).
- **`act_as_subject`** — **reserved name for user impersonation; feature deferred.**
  Not minted or honored in v1.
- **`scope`** — RFC 9068 / OAuth. See §7 for how it reconciles with derived-fresh
  permissions.
- **`client_id`** — RFC 9068.

### Why permissions are NOT in the token

`cx_auth_claims` derives permissions **fresh from the user's roles on every
request** today. Keeping that: a disabled user (`status`) and a revoked role take
effect on the **next request**, with no token blocklist. Baking permissions into
the token would reintroduce staleness and force per-access-token revocation
infrastructure we otherwise avoid. The token asserts *identity + tenant*;
authorization is recomputed each call.

---

## 7. Authorization model (scope ↔ permissions)

Effective permissions by token type:

- **User tokens (`authorization_code`):** `effective = intersection(token.scope
  → permissions, freshly-derived role permissions)`. A token can only **narrow**
  what roles already grant; roles remain source of truth (revocation stays
  instant). **v1:** first-party clients request a full-access scope, so the
  intersection is a no-op and behavior equals today's — the narrowing machinery is
  present but latent until fine-grained scopes exist.
- **M2M tokens (`client_credentials`):** no user, no roles → `effective = the
  client's granted scopes, mapped to cx permissions`. Requires a scope catalog +
  scope→permission map (deferred with third-party onboarding).

`#auth_context{}` gains a third shape (no record field change needed — the
existing fields express it):

| Actor | `user_id` | `subject` | `permissions` |
|---|---|---|---|
| Normal user | user id | identity subject | role-derived ∩ scope |
| Platform admin | `undefined` | identity subject | `{*}` |
| M2M client (later) | `undefined` | `client_id` | scope-mapped |

`cx_authz:require_user/1` already rejects `user_id = undefined`, so user-only
operations naturally exclude platform-admin and M2M tokens unless deliberately
allowed.

---

## 8. Signing keys

- **Table `cx_signing_key`**, keyed by **`kid` (bare binary)**, `disc_copies`
  (cluster-shared → every node signs/verifies with the same set). Fields: `kid`,
  `alg`, private key, public JWK, `status` (active | retiring), `created_at`,
  `not_after`.
- **Algorithm: RS256** — the safe interop default for anything consuming the JWKS
  (external verifiers, browsers, standard client libs). (The test harness's EdDSA
  is fine internally but RS256 is the conformant default.)
- **Rotation:** two-key overlap — mint a new `kid`, sign with it, keep the old key
  published in JWKS and accepted for verification until its longest-lived token
  expires, then retire. `cx_auth_jwt` already handles unknown-`kid` → refetch and
  multi-key verification.
- **Own-token verification is in-process**: a new `{local, ...}` `cx_auth_keys`
  source reads the public half directly — cx never HTTP-fetches its own JWKS.
- **JWKS exposure**: `/.well-known/jwks.json` serves the public keys for external
  verifiers and v2 federation symmetry.
- **At-rest (v1, documented limitation):** the private key sits in Mnesia
  `disc_copies` files protected by filesystem permissions only. Encryption-at-rest
  with a deployment secret is a flagged follow-up (§12), deferred as "easiest path,
  revisit."

---

## 9. Lifecycles

### 9.1 Login + tenant selection (`authorization_code` + PKCE)

1. SPA/mobile redirects to **`/authorize`** with `client_id`, `redirect_uri`,
   `response_type=code`, `scope` (incl. `openid`), `state`, `code_challenge`,
   `code_challenge_method=S256`, `nonce`.
2. cx **hosts the login UI** (new HTML surface): email + password. The client
   **never sees the password** — the property ROPC lacked.
3. Credential verified against `cx_identity` (constant-time; lockout per §12).
4. **Tenant selection, AS-side:**
   - member of exactly one tenant → auto-selected;
   - member of several → cx renders the **tenant picker**;
   - **platform admin** (holds `*`) → may target **any** tenant; selection mints
     `act_as_tenant`. Switching tenant later = re-run `/authorize` (cheap), which
     is why baking the target into a signed claim costs nothing.
5. cx issues a single-use **authorization code** (bound to `client_id`,
   `redirect_uri`, `code_challenge`, chosen tenant, `nonce`) and redirects back
   with `code` + `state`.
6. Client calls **`/token`** with `code` + `code_verifier`; cx verifies PKCE,
   returns **access + ID + refresh** tokens scoped to the chosen tenant.

No consent screen: first-party clients are pre-trusted, and third parties are M2M
(no user-present flow).

### 9.2 Refresh + revocation

- Access token ~10 min. Before expiry the client calls **`/token`
  (`grant_type=refresh_token`)**.
- **Rotation is mandatory** for public clients (RFC 9700): each refresh returns a
  **new** refresh token and invalidates the old. **Reuse detection**: presenting a
  rotated-away (already-used) refresh token revokes the whole chain (theft
  signal).
- **Revocation:** `cx_refresh_token` rows are revocable. **Logout** (`/revoke` or
  RP-initiated logout) revokes the current session's refresh token **and destroys
  the provider session** (§9.4). **Admin kill** (`force_stop_session`, existing)
  destroys the provider session, revokes all-for-subject, and force-closes the
  socket. (Immediate *access-token* cutoff mid-window is D12, deferred.)

### 9.3 WebSocket re-auth (token expiry on a live socket)

The socket does **not** die every 10 minutes, nor does it 401. Proactive in-band
re-auth:

1. Client refreshes its access token out-of-band (§9.2) shortly before `exp`.
2. Client pushes the new token into the **live** socket as a `reauth` frame (same
   in-band pattern as first-frame auth).
3. Server re-validates and **resets the socket's expiry deadline** (deadline =
   token `exp`). Missing/invalid re-auth before the deadline → close with a
   specific code (e.g. `4401`) meaning "re-login required."

This binds socket lifetime to token validity — **revocation works**: a revoked
refresh chain means the next re-auth fails and the socket drops within one
access-token window (≤10 min). Urgent case is instant via `force_stop_session`.

The 401→refresh→retry pattern remains correct and unchanged for ordinary REST.

### 9.4 Provider session, Remember-me & SSO

The `authorization_code` flow authenticates the **person** at the OP; that
authentication is held in a **provider session** — the OpenID-Provider-side login
session (the basis OIDC Session Management builds on). It is a **v1 component**,
not deferred.

- **Storage — `cx_provider_session`** (global, person-level, issuer-level; keyed
  by an opaque session id). Fields: `subject`, `authenticated_at`,
  `idle_expires_at`, `absolute_expires_at`, `remember_me`, `created_at`. Bound to
  the browser via a **`Secure`, `HttpOnly`, `SameSite=Lax` cookie**. The mobile
  app authenticates in the **system browser** (RFC 8252), which holds the same
  cookie — so a single provider session gives **SSO across SPA + mobile**.
- **Person-level, tenant-agnostic.** The session proves *who you are*, never
  *which tenant* — tenant is chosen per-authorization. This mirrors
  `cx_identity` being person-level and is what makes the tenant switcher cheap.
- **Remember-me** (login checkbox): checked → **persistent** cookie + long
  `absolute_expires_at` (e.g. 30 d) with an idle timeout; unchecked → **session**
  cookie + short idle timeout. Values are config.
- **Silent re-authorization (`prompt=none`).** When a client hits `/authorize`
  and a valid provider session exists, cx issues a code **without** a password
  prompt — the session is the proof. No session / expired / `prompt=login` → full
  login. This is what makes refresh-expiry, cold-start, and the second client
  seamless.
- **Tenant switch.** Because the session is tenant-agnostic, switching tenant is a
  **silent re-authorization selecting a different tenant** → new code → new tokens
  for the new tenant; **no password re-entry**, and the old tenant's tokens simply
  expire on their own. Multi-tenant users get a tenant switcher in the app that
  drives this; the same interaction covers a platform admin retargeting
  `act_as_tenant`.
- **Security.** Session id **rotated on authentication** (fixation defense);
  `Secure`/`HttpOnly`/`SameSite`; idle **and** absolute timeouts; **logout and
  admin-kill destroy the session and cascade-revoke its child refresh tokens**
  (the provider session is the parent of the refresh tokens minted under it).

---

## 10. Bootstrap

Chicken-and-egg: creating identities/clients requires admin, but a fresh
deployment has neither.

- **First admin identity:** config-seeded (successor to `platform_admin_subjects`).
  A seed identity with a default password (`"pass"` in dev) is created at first
  boot, **run through the real hasher** (never stored plaintext). Operator resets
  it near v1; refined later per owner.
- **First-party clients:** the SPA and mobile `client_id`s (+ redirect URIs) are
  seeded config, like the bootstrap admin.
- **First signing key:** generated at first boot if `cx_signing_key` is empty
  (§8), so the issuer can mint tokens immediately without an operator step.

---

## 11. Endpoint surface & REST integration

New endpoints (behavior per §9; **normative conformance in §13**):

| Endpoint | Purpose | Auth |
|---|---|---|
| `/.well-known/openid-configuration` | OP discovery metadata | public |
| `/.well-known/jwks.json` | public signing keys | public |
| `/authorize` | login UI + tenant picker → code | interactive |
| `/token` | code→tokens, refresh, client_credentials | client auth |
| `/userinfo` | OIDC claims about the user | access token |
| `/revoke` | RFC 7009 token revocation | client auth |
| `/introspect` | RFC 7662 token introspection | client/resource auth |
| RP-initiated logout | end session | per OIDC |

**Middleware:** `/authorize`, `/token`, `/revoke`, `/introspect`, discovery and
JWKS are **added to the `cx_rest_auth_middleware` bypass list** (alongside
`health`/`socket`/`docs`) — they *establish* auth and cannot require it.
`/userinfo` requires a valid access token.

**Layering — the one deliberate exception:** login/token/refresh operate
**without** an `#auth_context{}` (they *establish* identity). So there are two
surfaces:

- **Authentication** (pre-auth): `/authorize`, `/token`, credential verification —
  lives in `cx_auth` (issuer) over `cx_identity`/`cx_oauth_client` (core store).
- **Administration** (authz'd, normal rule): create/disable identity, register
  clients, assign roles — plain domain functions taking `#auth_context{}` first,
  `cx_authz:require/2` in the domain layer.

`cx_user` and the domain-authz rule are untouched.

---

## 12. Threat model (security-critical edges)

- **Password hashing** — PBKDF2-HMAC-SHA512, per-row salt, PHC-stored params,
  raisable cost (§4). Native, not hand-rolled.
- **Login rate-limiting / lockout** — per-identity `failed_count` + `locked_until`
  backoff; generic error + **constant-time dummy hash on unknown email**
  (enumeration resistance).
- **Tenant-membership disclosure** — the tenant picker appears **only after the
  password verifies** (never an email-only oracle). Pre-auth `/authorize` reveals
  nothing about membership.
- **Token lifetime / refresh / revocation** — short access token; refresh rotation
  + **reuse detection** (theft response); revocable store; instant admin kill.
- **PKCE** — S256 required for public clients; codes single-use, ≤60 s, bound to
  client/redirect/challenge.
- **Redirect URIs** — exact-match registered; native-app rules (RFC 8252).
- **Signing-key rotation** — overlap window, per-`kid`, JWKS-published;
  clock-skew leeway already ±30 s in `cx_auth_jwt`.
- **Key at rest** — **open item:** filesystem-perms only in v1; encryption-at-rest
  deferred (documented, revisit).
- **Sender-constrained tokens (DPoP/mTLS)** — **candidate SHOULD deferral**;
  decided in §13.

---

## 13. RFC / OIDC conformance matrix

> **Populated from the RFC/spec text directly (parallel fetch of RFC 6749, 6750,
> 7636, 8252, 9700, 9068, 7009, 7662, 8414 and OIDC Core/Discovery).** Each row:
> normative keyword, requirement, source §, and cx's conformance status
> (`met` / `deferred+justification` / `n/a`). This section is the "no shortcuts"
> audit. **All streams extracted** (RFC 6749/6750, 7636/8252/9700/9207,
> OIDC Core/Discovery, 9068/8414/7009/7662) from live spec text.
>
> **Genuine implementation deltas vs. cx today** (everything else is standard-
> correct new handler behavior):
> 1. **RFC 6750 §3 / OIDC §5.3.3** — protected-resource 401/403 must emit a
>    `WWW-Authenticate: Bearer` challenge alongside our RFC 9457 problem+json.
> 2. **RFC 9068 §4** — `cx_auth_jwt:verify/1` gains a `typ = at+jwt` header check
>    for access tokens (today it checks `alg/iss/aud/exp/nbf` only).
> 3. **OIDC Discovery §3** — production `issuer` MUST be `https` (dev is
>    `http://localhost:8081`); assert at boot, like the JWKS insecure-URL guard.
> 4. **RFC 9207** — emit the `iss` authorization-response parameter (chosen *not*
>    deferred; see §13.5).

### 13.1 RFC 6749 — Authorization endpoint (`/authorize`)

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | Authenticate the resource owner before processing | 3.1 | met (§9.1 step 3) |
| MUST | TLS on the authorization endpoint | 3.1 | met (deployment TLS; assert at boot) |
| MUST | Support HTTP GET | 3.1 | met |
| MUST NOT | No fragment in the endpoint URI | 3.1 | met |
| MUST | `response_type=code` required; else error per 4.1.2.1 | 3.1.1/4.1.1 | met |
| MUST | `client_id` required | 4.1.1 | met (validated vs `cx_oauth_client`) |
| MUST | Code required in success response; expires shortly; single-use | 4.1.2 | met (`cx_authorization_code`, ≤60 s, single-use) |
| MUST | Echo `state` in success **and** error responses when present | 4.1.2 / 4.1.2.1 | met |
| MUST NOT | On bad/missing `redirect_uri` or `client_id`, do **not** redirect to it | 4.1.2.1 | met (render error, no open redirect) |
| MUST | `error` from the defined set of 7 codes | 4.1.2.1 | met (`invalid_request`, `unauthorized_client`, `access_denied`, `unsupported_response_type`, `invalid_scope`, `server_error`, `temporarily_unavailable`) |
| — | Protocol hygiene: ignore unknown params, no duplicate params, valueless=omitted, preserve existing query | 3.1 | met (handler discipline) |
| SHOULD | `state` for CSRF | 4.1.1 | met (required of first-party clients) |
| SHOULD | Code lifetime ≤ 10 min | 4.1.2 | met (≤60 s, well under) |
| **SHOULD** | On code reuse, revoke all tokens previously issued from that code | 4.1.2 | **met** — code→refresh lineage tracked; reuse revokes the chain (ties to §9.2 reuse detection) |
| SHOULD | Inform resource owner on redirect/client validation failure | 4.1.2.1 | met (error page) |

### 13.2 RFC 6749 — Token endpoint (`/token`)

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | POST only | 3.2 | met |
| MUST | Confidential/credentialed clients authenticate (Basic supported) | 3.2.1 / 2.3.1 | met (integrator secret; Basic + `client_secret_post`) |
| MUST | Public client sends `client_id` when not authenticating | 3.2.1 | met |
| MUST | `authorization_code`: verify code validity, binding to client, identical `redirect_uri` | 4.1.3 | met |
| MUST | `refresh_token`: authenticate client, validate token, ensure issued-to-client; requested scope ⊆ original | 6 | met (§9.2; `cx_refresh_token` binds client+scope) |
| MUST | `client_credentials`: client authenticates; server authenticates client | 4.4.2 | met (grant present; integrators deferred) |
| MUST | Success body: `access_token`, `token_type` required; `scope` if differs | 5.1 | met |
| MUST | `Cache-Control: no-store` **and** `Pragma: no-cache` on token responses | 5.1 | met (set on `/token`) |
| MUST | Errors use HTTP 400 with `error` from the 6-code set | 5.2 | met (`invalid_request`, `invalid_client`, `invalid_grant`, `unauthorized_client`, `unsupported_grant_type`, `invalid_scope`) |
| SHOULD | HTTP 401 + `WWW-Authenticate` for `invalid_client` when HTTP-auth-scheme auth failed | 5.2 | met |
| SHOULD | `expires_in` in success | 5.1 | met |
| SHOULD NOT | No refresh token in a `client_credentials` response | 4.4.3 | met (M2M re-requests) |
| **SHOULD** | Refresh tokens expire/revoke after extended disuse | 6 / 5.1 | **met** — `cx_refresh_token` idle-expiry field |

### 13.3 RFC 6749 — Client registration / redirect URIs

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST NOT | `client_id` is not a secret; not sufficient alone for auth | 2.2 | met |
| MUST | Register redirect endpoint for public clients | 3.1.2.2 | met (`cx_oauth_client.redirect_uris`, seeded) |
| MUST | Redirect URI absolute, no fragment | 3.1.2 | met (validated at registration) |
| MUST | Compare supplied redirect URI vs registered; **exact string match** when full URI registered | 3.1.2.3 | met (exact match only — see also RFC 9700) |
| MUST | Protect client-password endpoints against brute force | 2.3.1 | met (rate-limit, §12) |
| MUST | TLS when sending client-secret auth | 2.3.1 | met |
| SHOULD | Require complete redirect URI registration | 3.1.2.2 | met |

### 13.4 RFC 6750 — Bearer token usage

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | Resource server supports `Authorization: Bearer` | 2.1 | met (existing `cx_auth:authenticate/1`) |
| MUST NOT | Not more than one token-transport method per request | 2 | met |
| MUST | TLS for all bearer requests | 5.3 | met (deployment) |
| MUST | `WWW-Authenticate: Bearer` challenge on missing/insufficient creds | 3 | **gap today** — add challenge header to 401s (currently RFC 9457 problem+json only); no duplicate `realm`/`scope`/`error` attrs |
| MUST | Error-code→status: `invalid_request`→400, `invalid_token`→401, `insufficient_scope`→403 | 3.1 | to implement on protected resources |
| SHOULD NOT | No `error` code in challenge when request carried no auth at all | 3.1 | met |

> **Carry-forward for implementation:** the one behavioral gap vs today is RFC
> 6750 §3 — protected-resource 401/403s must emit a `WWW-Authenticate: Bearer`
> challenge (alongside our RFC 9457 body). Everything else maps to standard-correct
> handler behavior.

### 13.5 RFC 7636 / 8252 / 9700 / 9207 (PKCE, native apps, security BCP, mix-up)

**PKCE (RFC 7636 + RFC 9700 §2.1.1)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | Public clients use PKCE; AS supports & advertises it | 9700 §2.1.1 | met (mandatory for SPA + mobile) |
| MUST | `code_verifier` 43–128 unreserved chars, ≥256-bit entropy | 7636 §4.1/§7.1 | met (client-side; documented) |
| MUST | If client can `S256`, it MUST use `S256` (server MTI) | 7636 §4.2 | met (`S256` only; `plain` refused) |
| MUST | AS binds `code_challenge`+method to the code | 7636 §4.4 | met (`cx_authorization_code`) |
| MUST | Token endpoint requires matching `code_verifier`; else `invalid_grant` | 7636 §4.6 | met |
| MUST | Downgrade defense: accept `code_verifier` only if a `code_challenge` was sent | 9700 §2.1.1 | met |
| SHOULD | Publish `code_challenge_methods_supported` in metadata | 9700 §2.1.1 | met (discovery doc, §13.6) |

**Native app (RFC 8252) — mobile client**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | Authorization via external **system browser**, never an embedded webview | 8252 §4/§8.12 | met (client contract; documented for mobile team) |
| MUST | Offer the 3 redirect options (private-use scheme / loopback / claimed https); exact-match | 8252 §7/§8.4 | met (`redirect_uris` supports all three) |
| MUST | Register native app as **public**; even if it sends a secret, treat as public | 8252 §8.4/§8.5 | met (`client_type=public`; secret ignored) |
| MUST | Loopback redirect: allow **any port** at request time | 8252 §7.3 | met (special-case in matcher — the one exception to exact match) |
| SHOULD | Reject native auth requests lacking PKCE | 8252 §8.1 | met |

**Redirect URIs / open redirect / prohibited grants (RFC 9700)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | **Exact string match** of redirect URIs (sole exception: native loopback port) | 9700 §2.1 | met |
| MUST NOT | No open redirectors on client or AS | 9700 §2.1 | met |
| MUST | Auth code single-use; invalidate after first redemption | 6749 §4.1.2 (reaffirmed 9700 §4.5) | met |
| MUST NOT | ROPC MUST NOT be used | 9700 §2.4 | met (never implemented — this is the whole pivot) |
| SHOULD NOT | Implicit / token-in-auth-response not used | 9700 §2.1.2 | met (`code` only) |
| MUST NOT | Auth responses never over cleartext | 9700 §2.6 | met (TLS) |
| MUST NOT | Access tokens never in a URI query param | 9700 §4.3.2 | met (Bearer header) |

**Refresh-token replay protection (RFC 9700 §4.14.2 / §2.2.2) — hard MUST**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| **MUST** | Detect refresh replay for public clients via **rotation** *or* sender-constraining | 9700 §4.14.2 | **met via rotation + reuse-detection** (§9.2) — this is the mandatory floor; DPoP is *not* required to satisfy it |
| MUST | Refresh tokens bound to their granted scope | 9700 §4.14.2 | met (`cx_refresh_token.scope`) |
| SHOULD | Refresh tokens expire on prolonged inactivity | 9700 §4.14.2 | met (idle-expiry field) |

**Mix-up defense — `iss` in authorization response (RFC 9207 / RFC 9700 §4.4)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| SHOULD (→REQUIRED once client talks to >1 AS) | `iss` mix-up countermeasure | 9700 §2.1/§4.4 | **implement now, not deferred** — v2 federation makes the REQUIRED trigger inevitable; cheap now |
| MUST | AS includes `iss` in success **and** error auth responses; sets `authorization_response_iss_parameter_supported=true`; metadata `issuer` == `iss` | 9207 §2/§2.3 | met (design decision below) |

> **Design decision from this fetch:** cx emits the RFC 9207 `iss` parameter on
> all `/authorize` responses and advertises
> `authorization_response_iss_parameter_supported=true`. Rationale: it's a SHOULD
> today but becomes REQUIRED the moment the first-party clients also talk to an
> external OP (v2 federation), and it's near-free to add up front. **Not deferred.**

### 13.6 OIDC Core / Discovery, RFC 9068 / 8414 / 7009 / 7662

**ID Token (OIDC Core §2, validation §3.1.3.7)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | ID Token signed via JWS (RS256) | §2 | met |
| REQUIRED | `iss`, `sub`, `aud`, `exp`, `iat` | §2 | met |
| MUST | `aud` **contains the `client_id`** (distinct from the access token's `aud=cx-api`) | §2 | met (§6 token table) |
| MUST NOT | `sub` > 255 ASCII | §2 | met (`sub` is a `cx_id` UUID) |
| REQUIRED | echo `nonce` when the request carried one | §2 | met |
| MUST NOT | `alg=none` (code flow returns no ID token from `/authorize`, so moot; never registered) | §2 | met |

**OIDC Authentication Request (code flow, §3.1.2.1)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| REQUIRED | `scope` **MUST contain `openid`** | §3.1.2.1 | met |
| REQUIRED | `response_type=code`, `client_id`, `redirect_uri` (exact-match) | §3.1.2.1 | met |
| OPTIONAL | `nonce` (optional in code flow; we accept + echo) | §3.1.2.1 | met |

**UserInfo (§5.3)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | `https`; accept Bearer access token (RFC 6750) | §5.3/§5.3.1 | met |
| MUST | always return `sub`; matches ID Token `sub` | §5.3.2 | met |
| MUST | `application/json` (or `application/jwt` if signed) | §5.3.2 | met (plain JSON v1) |
| MUST | errors per RFC 6750 §3 (`401 WWW-Authenticate: Bearer error="invalid_token"`) | §5.3.3 | met (ties to §13.4 challenge gap) |
| SHOULD | CORS for browser clients | §5.3 | met (SPA) |

**Discovery `/.well-known/openid-configuration` (OIDC Discovery §3/§4)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| REQUIRED | `issuer`, `authorization_endpoint`, `token_endpoint`, `jwks_uri`, `response_types_supported`, `subject_types_supported`, `id_token_signing_alg_values_supported` | §3 | met |
| MUST | **RS256 in `id_token_signing_alg_values_supported`** | §3 | met (RS256 is our alg) |
| MUST | `issuer` = `https`, no query/fragment, == `iss` in tokens, == well-known URL prefix | §3/§4.3 | **prod delta** — current dev `issuer` is `http://localhost:8081`; production MUST be `https`, asserted at boot |
| MUST | `jwks_uri` uses `https`; JWK Set MUST NOT contain private keys | §3 | met |
| MUST | `application/json`, `200 OK`, omit empty-array claims | §4.2/§3 | met |
| RECOMMENDED | advertise `userinfo_endpoint`, `scopes_supported` (incl. `openid`), `code_challenge_methods_supported=[S256]`, `authorization_response_iss_parameter_supported=true` | §3 | met |

**RFC 8414 (AS metadata, `/.well-known/oauth-authorization-server`)** — overlaps
Discovery; primary target is the OIDC doc. Same `issuer`/`jwks_uri`/`https`
MUSTs; `token_endpoint_auth_signing_alg_values_supported` MUST NOT list `none`.
Status: met (served alongside the OIDC discovery doc).

**RFC 9068 (JWT access-token profile) — affects the verify path**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | header `typ = at+jwt` | §2.1 | **verify delta** — `cx_auth_jwt` currently checks `alg/iss/aud/exp/nbf`; add a `typ=at+jwt` check for access tokens |
| MUST | signed; `alg` never `none`; RS256 supported | §2.1 | met (allow-list already excludes `none`) |
| REQUIRED | claims `iss, exp, aud, sub, client_id, iat, jti` | §2.2 | met (§6) |
| MUST | `aud` = a resource indicator the RS expects (default when no `resource`) | §3/§4 | met (`aud=cx-api`; RS checks it — existing `audience_ok`) |
| SHOULD | `sub` = user (user grants) or client id (client-credentials) | §2.2 | met (§7 auth_context table) |
| SHOULD | include `scope` when the grant carried one | §2.2.3 | met |

**RFC 7009 (revocation `/revoke`)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | support **refresh-token** revocation | §2 | met (§9.2) |
| MUST | search all token types if `token_type_hint` misses | §2.1 | met |
| MUST | authenticate the client; a client revokes **only its own** tokens | §2.1 | met |
| MUST | invalidation immediate | §2.1 | met (`cx_refresh_token` revoked flag) |
| MUST | `200 OK` for revoked **or** invalid token | §2.2 | met |
| MUST | HTTPS only | §2 | met |
| SHOULD | revoke access tokens too; cascade-invalidate grant siblings | §2/§2.1 | met (cascade on refresh revoke) |

**RFC 7662 (introspection `/introspect`)**

| Kw | Requirement | § | cx status |
|---|---|---|---|
| MUST | TLS; **require authorization to call** (block token scanning) | §2/§2.1 | met (client/RS auth) |
| REQUIRED | `token` param (POST form); `active` boolean in response | §2.1/§2.2 | met |
| MUST | inactive/expired/revoked → `active:false` | §2.2 | met |
| SHOULD NOT | no extra claims for an inactive token | §2.2 | met |

> **Note:** cx's own resource server validates the self-contained JWT access
> token **locally** (§8 in-process keys), so `/introspect` exists for
> spec-completeness and future opaque-token / third-party consumers rather than
> the first-party hot path.

### Consciously-deferred SHOULDs (itemized with justification)

All deferrals are SHOULD/RECOMMENDED (no MUST is deferred). Each cites the exact
requirement so the justification stands against the "every SHOULD" bar.

- **Sender-constrained access tokens — DPoP (RFC 9449) / mTLS (RFC 8705)** — SHOULD,
  RFC 9700 §2.2.1. **Deferred to v1.1.** Heaviest lift in the whole spec set: DPoP
  means per-request proof-JWT signing on the SPA *and* mobile client, `htm/htu/iat/
  jti/ath/nonce` handling, `DPoP-Nonce` challenges, `cnf`/`jkt` binding, and server
  `jti` replay tracking; mTLS is impractical for a browser SPA. **Critical
  distinction:** this does **not** defer refresh-token replay protection — that is a
  MUST (RFC 9700 §4.14.2) and is **met** via rotation + reuse detection (§9.2), the
  spec's lighter alternative branch.
- **Access-token audience/least-privilege restriction** — SHOULD, RFC 9700 §2.3.
  **Deferred** while there is a single resource server (`cx-api`); we document the
  single-audience assumption. Revisit when a second resource server or fine-grained
  scopes land (same trigger as the latent scope-narrowing in §7).
- **Refresh-token inactivity expiry** — SHOULD, RFC 9700 §4.14.2. **Met** (idle-
  expiry field on `cx_refresh_token`) — listed here only to record it was
  considered, not skipped.

**Explicitly NOT deferred despite being SHOULD:** the RFC 9207 `iss` mix-up
parameter (§13.5) — cheap now, REQUIRED once v2 federation lands.

---

## 14. Data-model & DoD impact

New **platform-global auth tables** (bare-keyed, issuer-level — a deliberate,
named expansion of the `cx_tenant` "not tenant-keyed" exception; isolation is
preserved because none exposes another tenant's *domain* data):

- `cx_identity` (key `subject`; unique index on `email`)
- `cx_oauth_client` (key `client_id`)
- `cx_signing_key` (key `kid`)
- `cx_refresh_token` (key opaque handle)
- `cx_authorization_code` (key opaque code; `ram_copies`, cluster-replicated)
- `cx_provider_session` (key opaque session id; Remember-me → `disc_copies`)

All registered in `cx_db:table_specs/0`; all match patterns added to
`cx_patterns`; all records eqWAlizer-honest (no `'_'` in field unions). `cx_`
prefix is correct (each is a persisted Mnesia table). New value records
(`#auth_context{}` unchanged; any PKCE/PHC helpers) stay unprefixed.

Gates unchanged and mandatory: `rebar3 compile` (zero warnings), `fmt --check`,
`eunit`, `ct`, `elp eqwalize-all` (NO ERRORS), `elp lint --diagnostic-ignore
W0051`. `cx_auth_test` already mints real signed JWTs — the CT/eunit issuing
surface extends from it.

---

## 15. Deferral register — what is explicitly NOT in v1

The single authoritative list of everything deferred. Each entry: **target**,
**why**, and the **trigger** that should re-activate it. Nothing here is a MUST;
all are SHOULD/RECOMMENDED or product scope.

| # | Deferred item | Target | Why deferred | Re-activation trigger |
|---|---|---|---|---|
| D1 | **OIDC federation** (cx as Relying Party to AD/Entra/Okta) | v2 | On-prem debuggability wants the local issuer first; the verify seam is preserved, so this is additive | First enterprise customer that mandates their own IdP |
| D2 | **Third-party integrator onboarding** — external client registration, M2M scope catalog, scope→permission map | later | Grant machinery (`client_credentials`, `cx_oauth_client`) is built; only the *product* surface waits | First integrator; or when fine-grained scopes are needed |
| D3 | **MFA** (TOTP / passkey) | v1.1 | `cx_identity` is shaped so a `cx_credential` child table is additive (§4) — no migration | Security requirement / customer demand |
| D4 | **Self-service password reset** (forgot-password) | v1.1 | Needs an outbound transactional email/SMS path; admin-set + authenticated self-change ship in v1 | Outbound channel available |
| D5 | **Sender-constrained tokens** — DPoP (RFC 9449) / mTLS (RFC 8705) | v1.1 | SHOULD (RFC 9700 §2.2.1); heaviest lift (per-request proof-JWT on SPA+mobile). Does **not** defer refresh replay protection (that MUST is met by rotation, §9.2) | Threat model demands token binding |
| D6 | **Access-token audience/least-privilege restriction** | when >1 RS | SHOULD (RFC 9700 §2.3); single resource (`cx-api`) today | A second resource server or fine-grained scopes |
| D7 | **Fine-grained scope narrowing** for user tokens | with D2 | Machinery present but latent (§7); first-party clients request full-access scope | Fine-grained/third-party scopes |
| D8 | **Signing-key encryption-at-rest** | TBD (§16.2) | "Easiest path" for v1 = filesystem perms; documented limitation | Owner decision / hardening pass |
| D9 | **Dynamic client registration** (RFC 7591) | not planned | Clients are seeded or admin-registered | A use case that needs programmatic registration |
| D10 | **`act_as_subject` user impersonation** | when needed | Claim name reserved (§6); feature has audit weight, build deliberately | Supervisor-impersonation product need |
| D11 | **Front-channel / back-channel logout** (OIDC) | TBD (§16) | v1 logout = revoke refresh + clear provider session; multi-client single-logout is heavier | Multiple RPs needing coordinated logout |
| D12 | **Immediate access-token revocation** (denylist by `jti`, or store-and-remove) | v1.x | Access tokens are short-lived self-contained JWTs (unstored); v1 cutoff = refresh revocation (≤10 min) + provider-session destroy + `force_stop_session` (instant socket). Severing a live access-token window needs a `jti` denylist checked at verify | Need to cut a user off mid-access-token-window |
| D13 | **Login-UI theming / branding / localization** | follow-up PRs | v1 ships functional, unbranded, English `/authorize` pages; graphics fine-tuned after | Design/brand pass |

Every row above is also cross-referenced from its originating section. The
conformance matrix (§13) is the proof that no **MUST** appears in this table.

---

## 16. Open decisions carried into review

1. **Global-table expansion** — do you bless growing the "not tenant-keyed"
   exception from `cx_tenant` alone to the six issuer-level auth tables above?
   (They are inherently above tenants; the alternative is contorting issuer state
   into `{TenantId, Id}` keys, which would be dishonest.)
2. **Every-SHOULD posture** — confirm the "accept or defer-with-justification per
   SHOULD" approach (§13), with DPoP as the leading deferral candidate.
3. **v1 scope confirmation** — `client_credentials` present-but-unonboarded;
   scope-narrowing latent; federation v2. (Stated in §1.)
4. **Key at rest** — accept filesystem-perms-only for v1 (§8/§12), or pull
   encryption-at-rest into v1?
```
