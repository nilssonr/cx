# cx — working agreements

Multi-tenant contact center on Erlang/OTP (rebar3 umbrella; OTP 29+).
See README.md for architecture. "Interaction" is the canonical term for a
customer session; media types are tenant data, never a code enum.

## Definition of done

A change is done only when ALL of these pass:

    rebar3 compile                  # zero warnings in apps/ (deps excluded)
    rebar3 fmt --check              # erlfmt clean (ELP does NOT format)
    rebar3 eunit                    # unit tests + PropEr properties
    rebar3 ct                       # router flows + REST e2e
    elp eqwalize-all                # must end with "NO ERRORS"
    elp lint --read-config          # must report no diagnostics

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
  rows (`cx_store`), app env (`cx_cfg`), JSON decode (`cx_json`). Do not
  sprinkle it inland to silence errors — refine with guards/pattern
  matches instead.
- Module-level `-eqwalizer(ignore).` is reserved for macro-generated code
  that cannot typecheck (currently: cx_patterns, PropEr test modules).
  Adding one anywhere else needs a stated reason in the module header.

## Conventions

- Every Mnesia key is `{TenantId, Id}`; cross-tenant references must stay
  inexpressible. New tables follow the same shape and are added in
  `cx_db:table_specs/0`.
- Every domain operation is a plain function taking `#auth_ctx{}` as its
  first argument; `cx_authz:require/2` is called in the domain layer,
  never in transports. REST handlers only decode → call → `cx_h:reply`.
- Processes: named generic timeouts only (never `erlang:send_after` in
  gen_statem); queues call sessions, sessions never call queues (the
  facade talks to both) — keep it that way to stay deadlock-free.
- Every state transition publishes a `cx_event`; new features follow.
- There is no "auth disabled" mode and none may be added; tests mint real
  JWTs via `cx_auth_test` with a static key source.
- Timestamps: `erlang:system_time(millisecond)`. IDs: `cx_id:new()`.
