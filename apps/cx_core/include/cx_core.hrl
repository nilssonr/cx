-ifndef(CX_CORE_HRL).
-define(CX_CORE_HRL, true).

%% All IDs are UUIDv4 binaries (cx_id:new/0). All stored timestamps are
%% erlang:system_time(millisecond). Every table key is {TenantId, Id}
%% except cx_tenant, so cross-tenant references are inexpressible.
%%
%% Mnesia match patterns ('_' wildcards) intentionally violate these
%% field types — construct them only via cx_patterns, which is exempt
%% from eqWAlizer, so the types stay honest everywhere else.

%% Produced by cx_auth from a validated token; consumed by every domain
%% function. Lives in cx_core (not cx_auth) because cx_core enforces
%% permissions and cx_auth depends on cx_core.
-record(auth_context, {
    tenant_id :: binary(),
    user_id :: binary() | undefined,
    subject :: binary() | undefined,
    permissions :: sets:set(binary()),
    claims = #{} :: map()
}).

-record(cx_tenant, {
    id :: binary(),
    name :: binary(),
    status = active :: active | suspended,
    created_at :: integer(),
    updated_at :: integer()
}).

-record(cx_user, {
    key :: {binary(), binary()},
    %% OIDC "sub" claim; indexed — cx_auth resolves tokens through it.
    subject :: binary() | undefined,
    name :: binary(),
    email :: binary(),
    role_ids = [] :: [binary()],
    skills = #{} :: #{binary() => pos_integer()},
    routing_profile_id :: binary() | undefined,
    status = active :: active | disabled,
    created_at :: integer(),
    updated_at :: integer()
}).

-record(cx_role, {
    key :: {binary(), binary()},
    name :: binary(),
    permissions = [] :: [binary()]
}).

%% Proficiency levels are a tenant-named ordinal scale: comparisons are
%% only ever rank >= rank within one skill, never arithmetic across skills.
-record(cx_skill, {
    key :: {binary(), binary()},
    name :: binary(),
    levels = [] :: [{pos_integer(), binary()}]
}).

%% Widening steps are sorted ascending by AfterMs with non-increasing
%% ranks (validated at config write); each step REPLACES min_rank.
-record(skill_requirement, {
    skill_id :: binary(),
    min_rank :: pos_integer(),
    widening = [] :: [{AfterMs :: pos_integer(), MinRank :: pos_integer()}]
}).

-record(cx_queue, {
    key :: {binary(), binary()},
    name :: binary(),
    skill_requirements = [] :: [#skill_requirement{}],
    %% no record defaults on purpose: the creation defaults live in
    %% cx_queue:create/2, so every construction states its values and
    %% eqWAlizer rejects one that forgets
    wrapup_duration_ms :: non_neg_integer(),
    %% cap on TOTAL after-call work per interaction (initial duration plus
    %% extensions); infinity = uncapped (0 on the wire)
    wrapup_max_ms :: pos_integer() | infinity,
    %% ring time for an offer; infinity = ring forever (0 on the wire)
    offer_timeout_ms :: pos_integer() | infinity,
    %% when true, after-call work cannot finalize (timer, DELETE or
    %% sign-out) until the interaction carries qualification codes —
    %% entering them is what releases the agent
    qualification_required :: boolean(),
    status = open :: open | closed
}).

%% "If I'm handling >= AtLeast of when_media, don't route me any of block."
-record(routing_profile_guard, {
    when_media :: binary(),
    at_least :: pos_integer(),
    block = [] :: [binary()]
}).

-record(cx_routing_profile, {
    key :: {binary(), binary()},
    name :: binary(),
    max_total = unlimited :: pos_integer() | unlimited,
    media_capacities = #{} :: #{binary() => pos_integer()},
    guards = [] :: [#routing_profile_guard{}]
}).

-record(cx_not_ready_reason, {
    key :: {binary(), binary()},
    name :: binary(),
    active = true :: boolean()
}).

%% Hierarchical classification codes applied to interactions during
%% completion/after-call work. parent_id links form a tenant-scoped tree
%% (undefined = root); ANY active node is selectable — interior nodes
%% included (the UI drills down through cascading dropdowns and may stop
%% at any level).
-record(cx_qualification_code, {
    key :: {binary(), binary()},
    name :: binary(),
    parent_id :: binary() | undefined,
    active = true :: boolean()
}).

%% enqueued_at + sequence form the queue position and are assigned exactly once;
%% requeues (reject/timeout/crash) and queue-process recovery reuse them, so
%% an interaction can never lose its place.
%%
%% Lifecycle: queued -> offered -> active <-> held -> wrapup -> completed
%% (wrapup is skipped when the queue's wrapup_duration_ms is 0; cancelled
%% is reachable from queued only). "completed" is terminal INCLUDING
%% after-call work: the customer part ends at wrapup entry, the agent is
%% released at completed.
-record(cx_interaction, {
    key :: {binary(), binary()},
    queue_key :: {binary(), binary()},
    %% one of cx_media:all() — media types are product concepts, not data
    media_type :: binary(),
    properties = #{} :: #{binary() => binary()},
    state = queued :: queued | offered | active | held | wrapup | completed | cancelled,
    agent_id :: binary() | undefined,
    created_at :: integer(),
    enqueued_at :: integer(),
    sequence :: integer(),
    accepted_at :: integer() | undefined,
    wrapup_started_at :: integer() | undefined,
    wrapup_until :: integer() | undefined,
    %% cx_qualification_code ids (any node of the tree, interior included)
    qualification_ids = [] :: [binary()],
    completed_at :: integer() | undefined
}).

%% Durable DECLARED collaboration presence, written only by
%% cx_presence:set_own. Row absence == fully automatic, no message.
%% `until` (ms) expires manual_state AND message together; it is only
%% ever COMPARED to now, never rewritten — so connectionless users
%% expire lazily with no process (and no event fires at that moment;
%% clients self-expire using the `until` in presence payloads).
-record(cx_presence_declaration, {
    key :: {binary(), binary()},
    %% one of cx_presence_state:all(); undefined = automatic
    manual_state :: binary() | undefined,
    message :: binary() | undefined,
    until :: integer() | undefined,
    updated_at :: integer()
}).

%% ram_copies cache of EFFECTIVE collaboration presence, written by a
%% live cx_presence_session on every transition and deleted when it
%% stops. Invariant: a row exists iff a session process owns it; read
%% paths treat dead-pid rows as absent. Cache, never authoritative.
-record(cx_presence_effective, {
    key :: {binary(), binary()},
    pid :: pid(),
    %% one of cx_presence_state:all()
    state :: binary(),
    message :: binary() | undefined,
    until :: integer() | undefined,
    device_count = 0 :: non_neg_integer(),
    updated_at :: integer()
}).

%% ram_copies cache of live agent-session state, written by the session on
%% every transition. Routing reads it dirty; the offer call to the session
%% is the authoritative check. Never treat this row as truth.
-record(cx_agent_snapshot, {
    key :: {binary(), binary()},
    pid :: pid(),
    ready = #{} :: #{binary() => ready | {not_ready, binary() | undefined}},
    %% per-media counts of everything occupying capacity: active + held +
    %% after-call work + reserved (pending offers) — wrap-up is not a
    %% separate routing gate, it occupies its slot through this mix
    mix = #{} :: #{binary() => non_neg_integer()},
    skills = #{} :: #{binary() => pos_integer()},
    profile :: #cx_routing_profile{} | undefined,
    idle_since = 0 :: integer()
}).

%% ---- Issuer-level auth tables (OAuth 2.0 / OIDC provider) ----
%%
%% Unlike every other cx_* table these are NOT keyed {TenantId, Id}: they
%% model the issuer/identity layer that sits ABOVE tenants — a person, an
%% OAuth client, a signing key, a token, a login session — exactly as
%% cx_tenant does. Tenant scoping, where it applies, is a FIELD (tenant_id)
%% plus the token's tenant claim, never the key; cross-tenant domain data
%% stays inexpressible because none of these rows carry it.

%% The PERSON. One identity : many cx_user rows (one per tenant), joined by
%% #cx_user.subject. email is the global login handle (indexed, unique).
%% password_hash is a PHC string; undefined for a federated identity whose
%% credential lives in an external IdP.
%% Lockout is temporal (locked_until), distinct from administrative status.
-record(cx_identity, {
    subject :: binary(),
    email :: binary(),
    password_hash :: binary() | undefined,
    status = active :: active | disabled,
    failed_count = 0 :: non_neg_integer(),
    locked_until :: integer() | undefined,
    created_at :: integer(),
    updated_at :: integer()
}).

%% An OAuth client. client_id is globally unique. tenant_id = undefined for
%% first-party global clients (the SPA and mobile app); set for per-tenant
%% integrator clients using the client_credentials grant. secret_hash is a
%% SHA-256 of the client secret, present only for confidential clients.
-record(cx_oauth_client, {
    client_id :: binary(),
    tenant_id :: binary() | undefined,
    name :: binary(),
    client_type :: public | confidential,
    grant_types = [] :: [binary()],
    redirect_uris = [] :: [binary()],
    scopes = [] :: [binary()],
    secret_hash :: binary() | undefined,
    status = active :: active | disabled,
    created_at :: integer(),
    updated_at :: integer()
}).

%% A JWS signing key. `alg` is the canonical algorithm atom (cx_jws_alg,
%% e.g. rs256 | eddsa | hs256) — cx_core stays JWS-agnostic so the field is
%% typed atom() and refined at the cx_auth boundary. private_jwk is the
%% signing half; public_jwk is the JWKS-publishable half, `undefined` for a
%% symmetric key (no public half). status: active (sign with the newest) |
%% retiring (verify only, kept until its longest-lived token expires). The
%% private half is protected at rest by filesystem permissions only.
-record(cx_signing_key, {
    kid :: binary(),
    alg :: atom(),
    private_jwk :: map(),
    public_jwk :: map() | undefined,
    status = active :: active | retiring,
    created_at :: integer(),
    not_after :: integer() | undefined
}).

%% A stored, rotating refresh token. token_id is the id half of the opaque
%% handle (a hash of it — never the handle itself). Rotation chains link via
%% rotated_to; presenting an already-rotated token revokes the whole chain
%% (reuse detection, RFC 9700 §4.14.2). session_id ties it to the provider
%% session so logout / admin-kill cascade.
-record(cx_refresh_token, {
    token_id :: binary(),
    subject :: binary(),
    tenant_id :: binary(),
    client_id :: binary(),
    session_id :: binary() | undefined,
    scope = [] :: [binary()],
    rotated_to :: binary() | undefined,
    revoked = false :: boolean(),
    idle_expires_at :: integer() | undefined,
    expires_at :: integer(),
    created_at :: integer()
}).

%% A single-use authorization code (~60 s). Bound to the client, redirect_uri,
%% PKCE challenge, chosen tenant and nonce. ram_copies; redeemed exactly once
%% at /token. act_as_tenant is set only when the subject is a platform admin
%% acting on a tenant they are not a member of.
-record(cx_authorization_code, {
    code :: binary(),
    client_id :: binary(),
    subject :: binary(),
    tenant_id :: binary(),
    act_as_tenant :: binary() | undefined,
    session_id :: binary() | undefined,
    redirect_uri :: binary(),
    code_challenge :: binary(),
    code_challenge_method :: binary(),
    scope = [] :: [binary()],
    nonce :: binary() | undefined,
    expires_at :: integer(),
    created_at :: integer()
}).

%% The OpenID-Provider-side login session (the person's authenticated
%% session; SSO across the SPA and mobile app via the system-browser cookie).
%% Person-level and tenant-agnostic — the tenant is chosen per authorization,
%% never stored here. remember_me extends the absolute lifetime.
-record(cx_provider_session, {
    id :: binary(),
    subject :: binary(),
    remember_me = false :: boolean(),
    authenticated_at :: integer(),
    idle_expires_at :: integer(),
    absolute_expires_at :: integer(),
    created_at :: integer()
}).

-endif.
