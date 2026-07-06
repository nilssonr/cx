-module(cx_handler).

%% Shared handler plumbing: JSON body reading and the single place where
%% domain errors map to HTTP statuses. Handlers stay thin: decode ->
%% domain call -> reply.

-include_lib("cx_core/include/cx_core.hrl").

-export([reply/2, with_body/2, scope_tenant/2]).

-define(JSON, #{<<"content-type">> => <<"application/json">>}).

-spec reply(term(), cowboy_req:req()) -> cowboy_req:req().
reply(ok, Req) ->
    cowboy_req:reply(204, #{}, <<>>, Req);
reply({ok, Data}, Req) ->
    cowboy_req:reply(200, ?JSON, cx_json:encode(Data), Req);
reply({error, Error}, Req) ->
    cowboy_req:reply(
        status(Error),
        ?JSON,
        cx_json:encode(#{<<"error">> => error_bin(Error)}),
        Req
    ).

status(unauthorized) -> 401;
status(forbidden) -> 403;
status(no_user) -> 403;
status(not_found) -> 404;
status(no_session) -> 404;
status(method_not_allowed) -> 405;
status(already_exists) -> 409;
status(in_use) -> 409;
status(profile_missing) -> 409;
status(not_cancellable) -> 409;
status(expired) -> 409;
status(already_started) -> 409;
status(queue_closed) -> 409;
status(has_active_interactions) -> 409;
status(not_in_wrapup) -> 409;
status(not_active) -> 409;
status(not_held) -> 409;
status(conflict) -> 409;
status(wrapup_cap_exceeded) -> 409;
status(qualification_required) -> 409;
status({invalid, json}) -> 400;
status({invalid, _Field}) -> 422;
status(_) -> 500.

error_bin({invalid, Field}) when is_binary(Field) ->
    <<"invalid:", Field/binary>>;
error_bin({invalid, Field}) when is_atom(Field) ->
    FieldBin = atom_to_binary(Field),
    <<"invalid:", FieldBin/binary>>;
error_bin(Error) when is_atom(Error) ->
    atom_to_binary(Error);
error_bin(_) ->
    <<"internal_error">>.

%% Read + decode a JSON object body. Returns {Result, Req}.
-spec with_body(cowboy_req:req(), fun((map()) -> term())) ->
    {term(), cowboy_req:req()}.
with_body(Req0, Fun) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case cx_json:decode(Body) of
        {ok, Map} when is_map(Map) -> {Fun(Map), Req1};
        _ -> {{error, {invalid, json}}, Req1}
    end.

%% Admin routes carry :tenant_id. Operating on your own tenant is the normal
%% case; operating on another requires tenants:admin, and the ctx is
%% rescoped to the path tenant so every downstream key is built from it.
-spec scope_tenant(#auth_context{}, binary()) ->
    {ok, #auth_context{}} | {error, forbidden}.
scope_tenant(Ctx = #auth_context{tenant_id = TenantId}, TenantId) ->
    {ok, Ctx};
scope_tenant(Ctx, TenantId) ->
    case cx_authz:has(Ctx, <<"tenants:admin">>) of
        true -> {ok, Ctx#auth_context{tenant_id = TenantId}};
        false -> {error, forbidden}
    end.
