-module(cx_config).

-export([
    create_tenant/1,
    get_tenant/0,
    get_tenant/1,
    update_tenant/2,
    delete_tenant/1,

    create_not_ready_reason/1,
    get_not_ready_reason/1,
    get_not_ready_reason/2,
    delete_not_ready_reason/2,

    create_skill/1,
    get_skill/1,
    get_skill/2,
    delete_skill/2,

    create_user/1,
    get_user/1,
    get_user/2,
    delete_user/2
]).

%%%-------------------------------------------------------------------
%%% Public API
%%%-------------------------------------------------------------------

create_tenant(Name) ->
    gen_server:call(cx_tenant_server, {create, [{name, Name}]}).

get_tenant() ->
    gen_server:call(cx_tenant_server, {get}).

get_tenant(Id) ->
    gen_server:call(cx_tenant_server, {get, Id}).

update_tenant(Id, Values) ->
    gen_server:call(cx_tenant_server, {update, Id, Values}).

delete_tenant(Id) ->
    gen_server:call(cx_tenant_server, {delete, Id}).

create_not_ready_reason(Values) ->
    gen_server:call(cx_not_ready_reason_server, {create, Values}).

get_not_ready_reason(TenantId) ->
    gen_server:call(cx_not_ready_reason_server, {get, TenantId}).

get_not_ready_reason(TenantId, Id) ->
    gen_server:call(cx_not_ready_reason_server, {get, TenantId, Id}).

delete_not_ready_reason(TenantId, Id) ->
    gen_server:call(cx_not_ready_reason_server, {delete, [{tenant_id, TenantId}, {id, Id}]}).

create_skill(Values) ->
    gen_server:call(cx_skill_server, {create, Values}).

get_skill(TenantId) ->
    gen_server:call(cx_skill_server, {get, TenantId}).

get_skill(TenantId, Id) ->
    gen_server:call(cx_skill_server, {get, TenantId, Id}).

delete_skill(TenantId, Id) ->
    gen_server:call(cx_skill_server, {delete, [{tenant_id, TenantId}, {id, Id}]}).

create_user(Values) ->
    gen_server:call(cx_user_server, {create, Values}).

get_user(TenantId) ->
    gen_server:call(cx_user_server, {get, TenantId}).

get_user(TenantId, Id) ->
    gen_server:call(cx_user_server, {get, TenantId, Id}).

delete_user(TenantId, Id) ->
    gen_server:call(cx_user_server, {delete, [{tenant_id, TenantId}, {id, Id}]}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
