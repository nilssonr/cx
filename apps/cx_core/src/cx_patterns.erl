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
    qualification_codes/1,
    qualification_children/2,
    open_queues/0,
    interactions/1,
    agent_snapshots/1,
    presence_decls/1,
    presence_effs/1
]).

tenants() -> #cx_tenant{_ = '_'}.

users(TenantId) -> #cx_user{key = {TenantId, '_'}, _ = '_'}.

roles(TenantId) -> #cx_role{key = {TenantId, '_'}, _ = '_'}.

skills(TenantId) -> #cx_skill{key = {TenantId, '_'}, _ = '_'}.

queues(TenantId) -> #cx_queue{key = {TenantId, '_'}, _ = '_'}.

routing_profiles(TenantId) ->
    #cx_routing_profile{key = {TenantId, '_'}, _ = '_'}.

not_ready_reasons(TenantId) -> #cx_not_ready_reason{key = {TenantId, '_'}, _ = '_'}.

qualification_codes(TenantId) ->
    #cx_qualification_code{key = {TenantId, '_'}, _ = '_'}.

qualification_children(TenantId, ParentId) ->
    #cx_qualification_code{key = {TenantId, '_'}, parent_id = ParentId, _ = '_'}.

open_queues() -> #cx_queue{status = open, _ = '_'}.

interactions(TenantId) -> #cx_interaction{key = {TenantId, '_'}, _ = '_'}.

agent_snapshots(TenantId) -> #cx_agent_snapshot{key = {TenantId, '_'}, _ = '_'}.

presence_decls(TenantId) -> #cx_presence_decl{key = {TenantId, '_'}, _ = '_'}.

presence_effs(TenantId) -> #cx_presence_eff{key = {TenantId, '_'}, _ = '_'}.
