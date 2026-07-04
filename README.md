# cx

A multi-tenant contact center that sits on top of MX-ONE — or any
SIP-enabled PBX. Erlang/OTP.

Voice arrives later via CSTA Phase III. The foundation routes **Open
Media**: an interaction that is just a property bag an integrator puts on
a queue, flowing through the same tenanting, skills-based routing,
capacity rules, ready states and wrap-up that every future media type
(chat, email, voice) will use.

## Design in one breath

An **interaction** (any media type — voice, chat, sms, email,
open_media, social_media: hard-coded product concepts, each backing a
distinct agent-app UI) lands on a media-agnostic **queue**, waits with
its position
preserved no matter what, and is offered to the best **agent** whose
per-media **ready state**, **wrap-up** gate, tenant-defined ordinal
**skill levels** (no 1–100 theater) and configured **routing profile**
(caps like "at most X total, of which Y chats" and guards like "if I'm on
a call, no emails") admit it. No hard-coded capacity limits: an agent may
work three emails, six chats and two calls concurrently if their
configuration allows it — agents may be humans, bots, or integrator
nodes. Every transition publishes an event. AuthN is an external OIDC
server (Zitadel) behind a seam; authZ is cx's own. Storage is Mnesia for
now.

## Layout

| App | Responsibility |
|---|---|
| `cx_core` | Domain model, Mnesia (`cx_db`), events (`cx_event`), registry (`cx_reg`) |
| `cx_auth` | JWT validation against the issuer's JWKS, claims → tenant/permissions |
| `cx_router` | Agent sessions, queue processes, offers — pure decision core in `cx_routing` |
| `cx_presence` | Collaboration presence — pure precedence core in `cx_presence_calc` |
| `cx_api_rest` | Thin cowboy binding over the domain functions + the WebSocket push transport |

## Presence

Collaboration presence (who coworkers see) is SEPARATE from router
readiness (whether the router may assign work) — separate controls,
separate APIs. States are product concepts (`cx_presence_state`):
online, away, busy, dnd, offline, out_of_office — plus a free-text
message with an optional `until` expiry ("In Spain for two weeks").

The engine stores *declarations* (durable), observes *connectivity*
(live sockets — ephemeral, rebuilt from reality after any crash) and
*computes* effective presence as a pure function; the answer is never
stored, only cached. No devices connected → offline (message still
shown); manual state wins; idle → away; else online.

## The socket

`/api/v1/socket` is the push channel for the agent app: the user's own
router events (offers, wrap-up, session) plus tenant `presence_changed`
fan-out — and it doubles as the presence engine's connectivity source.
Auth is in-band (browsers can't set Authorization on a WebSocket):
first frame `{"type":"auth","token":...}` within 10s, then
`{"type":"ready",...}`. Client sends `{"type":"ping"}` (~25s) and
throttled `{"type":"activity"}` on user input. Close codes: 4400
protocol, 4401 auth, 4403 no agent identity, 4408 auth deadline, 4429
slow consumer (reconnect + resync via REST).

## Build & test

    rebar3 compile
    rebar3 eunit        # unit + PropEr properties (routing core invariants)
    rebar3 ct           # router flows + REST e2e (no external services needed)
    rebar3 shell        # dev node on http://localhost:8080

Tests mint real signed JWTs against a static key source — Zitadel is not
required for any test.

## Dev environment with Zitadel

    docker compose -f docker/docker-compose.yml up -d

Then in the Zitadel console (http://localhost:8081):

1. Create an organization per cx tenant. The org id is what cx reads from
   the `urn:zitadel:iam:org:id` claim — create the cx tenant row with a
   matching id, or map your first users via `platform_admin_subjects`.
2. Create a project + application with audience `cx-api` (matching
   `audiences` in `config/sys.config`).
3. Human agents sign in through your SPA (authorization code + PKCE);
   integrators use client credentials / private-key JWT. cx only ever
   sees the resulting Bearer token.

`config/sys.config` keys under `cx_auth`: `issuer`, `audiences`,
`key_source` (`{jwks, Url}` or `{static, [JWKMap]}`), `jwks_refresh_ms`,
`tenant_claim`, `platform_admin_subjects` (bootstrap: token subjects that
get full permissions without a user row — keep this list tiny).

## Trying the flow without Zitadel

In `rebar3 shell`:

```erlang
Kp = cx_auth_test:new_keypair(),
cx_auth_test:install(Kp, #{platform_admin_subjects => [<<"boss">>]}),
Token = cx_auth_test:token(Kp, #{<<"sub">> => <<"boss">>,
                                 <<"urn:zitadel:iam:org:id">> => <<"bootstrap">>}),
io:format("~s~n", [Token]).
```

Then drive the API with curl (see the walkthrough in `scripts/demo.sh`):
create a tenant and queue; create a user with a role and a
routing profile; start an agent session; go ready; POST an interaction;
poll the session for the offer; accept; complete; watch wrap-up gate the
next offer.

## Conventions

- Every Mnesia key is `{TenantId, Id}`; cross-tenant references are
  inexpressible by construction.
- Every domain operation is a plain function taking `#auth_ctx{}`;
  permissions are enforced in the domain, never in transports.
- References are validated at write time (unknown skill/role/profile ids
  are 422) and deletes are blocked while referenced (409 `in_use`) —
  both checked inside the write/delete transaction.
- Timestamps are `erlang:system_time(millisecond)`; ids are UUIDv4.
- The routing decision core (`cx_routing`) is pure — property-tested,
  no processes.
