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

-record(cx_media_type, {
    key :: {binary(), binary()},
    name :: binary(),
    config = #{} :: map()
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
    wrapup_duration_ms = 30000 :: non_neg_integer(),
    offer_timeout_ms = 30000 :: pos_integer(),
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

%% enqueued_at + seq form the queue position and are assigned exactly once;
%% requeues (reject/timeout/crash) and queue-process recovery reuse them, so
%% an interaction can never lose its place.
-record(cx_interaction, {
    key :: {binary(), binary()},
    queue_key :: {binary(), binary()},
    media_type_id :: binary(),
    properties = #{} :: #{binary() => binary()},
    state = queued :: queued | offered | active | completed | cancelled,
    agent_id :: binary() | undefined,
    created_at :: integer(),
    enqueued_at :: integer(),
    seq :: integer(),
    accepted_at :: integer() | undefined,
    completed_at :: integer() | undefined
}).

%% ram_copies cache of live agent-session state, written by the session on
%% every transition. Routing reads it dirty; the offer call to the session
%% is the authoritative check. Never treat this row as truth.
-record(cx_agent_presence, {
    key :: {binary(), binary()},
    pid :: pid(),
    ready = #{} :: #{binary() => ready | {not_ready, binary() | undefined}},
    %% active + reserved (pending offers) counts per media type
    mix = #{} :: #{binary() => non_neg_integer()},
    wrapup_until = 0 :: integer(),
    skills = #{} :: #{binary() => pos_integer()},
    profile :: #cx_routing_profile{} | undefined,
    idle_since = 0 :: integer()
}).

-endif.
