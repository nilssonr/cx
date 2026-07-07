-module(cx_handler).

%% Shared handler plumbing: JSON body reading and the single place where
%% domain errors map to HTTP statuses. Handlers stay thin: decode ->
%% domain call -> reply.

-include_lib("cx_core/include/cx_core.hrl").

-export([reply/2, with_body/2, scope_tenant/2, scope_tenant_header/2, problem/1, catalog/0]).

-define(JSON, #{<<"content-type">> => <<"application/json">>}).
-define(PROBLEM_JSON, #{<<"content-type">> => <<"application/problem+json">>}).

-spec reply(term(), cowboy_req:req()) -> cowboy_req:req().
reply(ok, Req) ->
    cowboy_req:reply(204, #{}, <<>>, Req);
reply({ok, Data}, Req) ->
    cowboy_req:reply(200, ?JSON, cx_json:encode(Data), Req);
reply({error, Error}, Req) ->
    {Status, Body} = problem(Error),
    cowboy_req:reply(Status, ?PROBLEM_JSON, cx_json:encode(Body), Req).

%% Every domain error atom, paired with its RFC 9457 title and HTTP status.
%% This one list is the source of truth for problem/1 and for the set of
%% error `type` URIs documented in openapi.yaml.
-spec catalog() -> [{atom(), binary(), 400..599}].
catalog() ->
    [
        {unauthorized, <<"Unauthorized">>, 401},
        {forbidden, <<"Forbidden">>, 403},
        {no_user, <<"No agent identity">>, 403},
        {not_found, <<"Not found">>, 404},
        {no_session, <<"No active session">>, 404},
        {method_not_allowed, <<"Method not allowed">>, 405},
        {already_exists, <<"Already exists">>, 409},
        {in_use, <<"Resource in use">>, 409},
        {profile_missing, <<"Routing profile missing">>, 409},
        {not_cancellable, <<"Not cancellable">>, 409},
        {expired, <<"Expired">>, 409},
        {queue_closed, <<"Queue closed">>, 409},
        {has_active_interactions, <<"Has active interactions">>, 409},
        {not_in_wrapup, <<"Not in wrap-up">>, 409},
        {not_active, <<"Not active">>, 409},
        {not_held, <<"Not held">>, 409},
        {conflict, <<"Conflict">>, 409},
        {wrapup_cap_exceeded, <<"Wrap-up cap exceeded">>, 409},
        {qualification_required, <<"Qualification required">>, 409}
    ].

%% Map a domain error to an RFC 9457 Problem Details body plus its HTTP status.
%% `type` is a stable URN (urn:cx:error:<name>); field validation carries an
%% `errors` extension array; anything unrecognized is a 500.
-spec problem(term()) -> {400..599, map()}.
problem({invalid, json}) ->
    {400, #{
        <<"type">> => type_uri(<<"malformed_json">>),
        <<"title">> => <<"Malformed JSON">>,
        <<"status">> => 400
    }};
problem({invalid, Field}) ->
    {422, #{
        <<"type">> => type_uri(<<"validation">>),
        <<"title">> => <<"Validation failed">>,
        <<"status">> => 422,
        <<"errors">> => [#{<<"field">> => field_bin(Field)}]
    }};
problem(Error) when is_atom(Error) ->
    case lists:keyfind(Error, 1, catalog()) of
        {Error, Title, Status} ->
            {Status, #{
                <<"type">> => type_uri(atom_to_binary(Error)),
                <<"title">> => Title,
                <<"status">> => Status
            }};
        false ->
            internal_problem()
    end;
problem(_) ->
    internal_problem().

-spec internal_problem() -> {500, map()}.
internal_problem() ->
    {500, #{
        <<"type">> => type_uri(<<"internal">>),
        <<"title">> => <<"Internal server error">>,
        <<"status">> => 500
    }}.

-spec type_uri(binary()) -> binary().
type_uri(Name) ->
    <<"urn:cx:error:", Name/binary>>.

-spec field_bin(term()) -> binary().
field_bin(Field) when is_binary(Field) -> Field;
field_bin(Field) when is_atom(Field) -> atom_to_binary(Field);
field_bin(_) -> <<"unknown">>.

%% Read + decode a JSON object body. Returns {Result, Req}.
-spec with_body(cowboy_req:req(), fun((map()) -> term())) ->
    {term(), cowboy_req:req()}.
with_body(Req0, Fun) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case cx_json:decode(Body) of
        {ok, Map} when is_map(Map) -> {Fun(Map), Req1};
        _ -> {{error, {invalid, json}}, Req1}
    end.

%% Admin routes act on the caller's own tenant (from the token) by default.
%% A platform admin targets a different tenant via the X-Tenant-Id header;
%% that requires tenants:admin and rescopes the context so every downstream
%% key is built from the header tenant. No header -> the token tenant.
-spec scope_tenant_header(#auth_context{}, cowboy_req:req()) ->
    {ok, #auth_context{}} | {error, forbidden}.
scope_tenant_header(Context, Req) ->
    case cowboy_req:header(<<"x-tenant-id">>, Req) of
        undefined -> {ok, Context};
        TenantId -> scope_tenant(Context, TenantId)
    end.

%% Own tenant is the normal case; a different tenant requires tenants:admin
%% and rescopes the context to it.
-spec scope_tenant(#auth_context{}, binary()) ->
    {ok, #auth_context{}} | {error, forbidden}.
scope_tenant(Context = #auth_context{tenant_id = TenantId}, TenantId) ->
    {ok, Context};
scope_tenant(Context, TenantId) ->
    case cx_authz:has(Context, <<"tenants:admin">>) of
        true -> {ok, Context#auth_context{tenant_id = TenantId}};
        false -> {error, forbidden}
    end.
