-module(cx_patterns).

%% Mnesia match patterns: '_' wildcards inherently violate the record
%% field types, so their construction is quarantined here and the module
%% is exempt from eqWAlizer. Everything else keeps honest record types.
%% Functions are unspecced on purpose — callers receive dynamic().

-eqwalizer(ignore).

-include("cx_core.hrl").

-export([
    tenants/0,
    users/1,
    roles/1,
    skills/1,
    queues/1,
    routing_profiles/1,
    not_ready_reasons/1,
    open_queues/0,
    presences/1
]).

tenants() -> #cx_tenant{_ = '_'}.

users(TenantId) -> #cx_user{key = {TenantId, '_'}, _ = '_'}.

roles(TenantId) -> #cx_role{key = {TenantId, '_'}, _ = '_'}.

skills(TenantId) -> #cx_skill{key = {TenantId, '_'}, _ = '_'}.

queues(TenantId) -> #cx_queue{key = {TenantId, '_'}, _ = '_'}.

routing_profiles(TenantId) ->
    #cx_routing_profile{key = {TenantId, '_'}, _ = '_'}.

not_ready_reasons(TenantId) -> #cx_not_ready_reason{key = {TenantId, '_'}, _ = '_'}.

open_queues() -> #cx_queue{status = open, _ = '_'}.

presences(TenantId) -> #cx_agent_presence{key = {TenantId, '_'}, _ = '_'}.
