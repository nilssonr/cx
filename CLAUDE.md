# cx — working agreements

Multi-tenant contact center on Erlang/OTP (rebar3 umbrella; OTP 29+).
See README.md for architecture. "Interaction" is the canonical term for a
customer session; media types are hard-coded product concepts
(cx_media:all/0 — voice, chat, sms, email, open_media, social_media),
each backing a distinct agent-app UI. Customers never define them;
integrator extensibility goes through open_media + properties. The
same charter covers presence states (cx_presence_state:all/0).

Collaboration presence (cx_presence) is separate from router readiness
and must stay uncoupled except through future explicit tenant policy
(the seam is cx_presence_session:recompute/1). Presence stores
declarations, observes connectivity, computes effective state — never
store the computed answer, only cache it (cx_presence_effective, dead-pid
rows are garbage). WebSocket auth is in-band first-frame (browsers
cannot set Authorization on sockets); agent permission for presence is
`presence:set:self`.

## Definition of done

A change is done only when ALL of these pass:

    rebar3 compile                       # zero warnings in apps/ (deps excluded)
    rebar3 fmt --check                   # erlfmt clean (ELP does NOT format)
    rebar3 eunit                         # unit tests + PropEr properties
    rebar3 ct                            # router flows + REST e2e
    elp eqwalize-all                     # must end with "NO ERRORS"
    elp lint --diagnostic-ignore W0051   # must report no diagnostics

W0051 (sigil string syntax) is ignored via the CLI flag on the gates:
`elp lint` only reads .elp_lint.toml when given --read-config, so the
flag is what the local gate and CI rely on — immune to schema drift
between ELP builds. The checked-in .elp_lint.toml exists solely for
the IDE: the language server auto-reads it and silences W0051 inline;
it has no effect on the CLI gates. It's a style non-decision — the
codebase uses <<"...">>; adopting ~"..." sigils would be a deliberate
sweep (elp lint --diagnostic-filter W0051 --apply-fix).

Never mark work complete with a failing or skipped gate. If a gate cannot
pass for a good reason, stop and say so instead of suppressing it.

CI (`.github/workflows/ci.yml`) enforces this same gate on every PR and
on pushes to main. Releases are cut by pushing a `v*` tag that matches
the relx release version (`.github/workflows/release.yml`) — merging
never releases.

## eqWAlizer rules

- Record types in `cx_core.hrl` stay honest — never add `'_'` (or other
  pattern atoms) to field type unions.
- Mnesia match patterns are constructed ONLY in `cx_patterns` (the one
  eqWAlizer-exempt src module). Need a new pattern? Add a function there.
- `eqwalizer:dynamic()` is for genuine dynamic boundaries only: Mnesia
  rows (`cx_store`), app env (`cx_config`), JSON decode (`cx_json`). Do not
  sprinkle it inland to silence errors — refine with guards/pattern
  matches instead.
- Module-level `-eqwalizer(ignore).` is reserved for macro-generated code
  that cannot typecheck (currently: cx_patterns, PropEr test modules).
  Adding one anywhere else needs a stated reason in the module header.

## Conventions

- Every Mnesia key is `{TenantId, Id}`; cross-tenant references must stay
  inexpressible. New tables follow the same shape and are added in
  `cx_db:table_specs/0`.
- Every domain operation is a plain function taking `#auth_context{}` as its
  first argument; `cx_authz:require/2` is called in the domain layer,
  never in transports. REST handlers only decode → call → `cx_handler:reply`.
- Processes: named generic timeouts only (never `erlang:send_after` in
  gen_statem); queues call sessions, sessions never call queues (the
  facade talks to both) — keep it that way to stay deadlock-free.
- Every state transition publishes a `cx_event`; new features follow.
- There is no "auth disabled" mode and none may be added; tests mint real
  JWTs via `cx_auth_test` with a static key source.
- Timestamps: `erlang:system_time(millisecond)`. IDs: `cx_id:new()`.

## Naming

- **Symbols spell the whole word.** Modules, functions, records,
  fields, atoms, config keys and wire keys use full words (`session`,
  not `sess`; `handler`, not `h`; `qualification_required`, not
  `q_required`). An abbreviation survives only as:
  1. OTP/Erlang idiom — `Pid`, `Ref`, `Acc`, `_sup`/`_app` module
     suffixes, `Ms`/`_ms` millisecond tags, `min_`/`max_` qualifiers;
  2. industry vocabulary stronger than its expansion — `jwt`, `jwks`,
     `jose`, RFC-fixed claim names (`exp`, `sub`, `kid`, …), `sms`,
     `dnd`, `db`, `id`, `json`, `ws` (WebSocket), `authz`, `crud`.
- **Variables.** Domain values spell the whole word and use the SAME
  word everywhere — one greppable name per concept (`TenantId`, never
  `T`; `InteractionId`, never `IId`). Rebinding chains use the OTP
  naught convention: `Name0` is the incoming value, intermediates are
  numbered, the FINAL binding is unsuffixed (`Queue0 → Queue1 →
  Queue`); use `New`/`Old` prefixes instead when the contrast is the
  point (`OldVsn`, `NewData`). Fixed-meaning idioms are fine at any
  scope: `H`/`T` in `[H|T]`, `K`/`V`, `F` (a fun), `N` (a count),
  `Acc`/`Acc0`/`AccIn`/`AccOut`, `Pid`, `Ref`, `Ms`, and single-letter
  pattern bindings where the pattern names the type (`W = #work{…}`
  used a line later). A function that needs `State0` through `State5`
  doesn't need better names — it needs factoring.
- **Record names are unique across the whole umbrella**, even though
  Erlang scopes them per module — identical names with different
  shapes in different files is silent confusion. gen_statem data
  records are named after the process they model (`#agent_session{}`,
  `#presence_session{}`, `#queue_state{}`); records for the same
  concept on different sides get qualified names (`#pending_offer{}`
  in the session vs `#placed_offer{}` in the queue).
- **`#cx_*` on a record means exactly one thing:** it is a persisted
  Mnesia table and the record name IS the table name (table names are
  node-global atoms, hence the prefix). In-memory value records stay
  unprefixed (`#auth_context{}`, `#skill_requirement{}`). Never prefix
  a value record; never leave a table record unprefixed.
