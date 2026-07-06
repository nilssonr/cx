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
-record(auth_ctx, {
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
-record(skill_req, {
    skill_id :: binary(),
    min_rank :: pos_integer(),
    widening = [] :: [{AfterMs :: pos_integer(), MinRank :: pos_integer()}]
}).

-record(cx_queue, {
    key :: {binary(), binary()},
    name :: binary(),
    skill_reqs = [] :: [#skill_req{}],
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

%% "If I'm handling >= Gte of when_media, don't route me any of block."
-record(rp_guard, {
    when_media :: binary(),
    gte :: pos_integer(),
    block = [] :: [binary()]
}).

-record(cx_routing_profile, {
    key :: {binary(), binary()},
    name :: binary(),
    max_total = unlimited :: pos_integer() | unlimited,
    media_caps = #{} :: #{binary() => pos_integer()},
    guards = [] :: [#rp_guard{}]
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

%% enqueued_at + seq form the queue position and are assigned exactly once;
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
    seq :: integer(),
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
-record(cx_presence_decl, {
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
-record(cx_presence_eff, {
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

-endif.
