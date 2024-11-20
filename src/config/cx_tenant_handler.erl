-module(cx_tenant_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, State) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case cowboy_req:path(Req) of
                <<"/api/tenants">> -> handle_get_tenants(Req, State);
                <<"/api/tenants/", Id/binary>> -> handle_get_tenant(Req, State, Id)
            end
    end.
% case cowboy_req:method(Req) of
%     <<"POST">> ->
%         handle_create_tenant(Req, State);
%     <<"GET">> ->
%         case cowboy_req:path(Req) of
%             <<"/api/tenants">> -> handle_get_tenants(Req, State);
%             <<"/api/tenants/", Id/binary>> re-> handle_get_tenant(Req, State, Id)
%         end;
%     <<"PUT">> ->
%         case cowboy_req:path(Req) of
%             <<"/api/tenants/", Id/binary>> -> handle_update_tenant(Req, State, Id)
%         end;
%     <<"DELETE">> ->
%         case cowboy_req:path(Req) of
%             <<"/api/tenants/", Id/binary>> -> handle_delete_tenant(Req, State, Id)
%         end
% end.

% handle_create_tenant(Req, State) ->
%     {ok, Body, Req1} = cowboy_req:read_body(Req),
%     #{<<"name">> := Name} = jsx:decode(Body),
%     case cx_tenant:create_tenant([{name, Name}]) of
%         {ok, Tenant} ->
%             {ok,
%                 cowboy_req:reply(
%                     201,
%                     #{<<"content-type">> => <<"application/json">>},
%                     jsx:encode(tenant:into_map(Tenant)),
%                     Req1
%                 ),
%                 State};
%         {error, bad_request} ->
%             {ok, cowboy_req:reply(400, #{}, <<"Bad request">>, Req1), State};
%         _ ->
%             {ok, cowboy_req:reply(500, #{}, <<"Internal server error">>, Req1), State}
%     end.

handle_get_tenants(Req, State) ->
    case cx_config:get_tenant() of
        {ok, Tenants} ->
            JsonTenants = jsx:encode(tenant_to_map(Tenants)),
            {
                ok,
                cowboy_req:reply(
                    200, #{<<"content-type">> => <<"application/json">>}, JsonTenants, Req
                ),
                State
            }
    end.

handle_get_tenant(Req, State, Id) ->
    io:format("~s~n", [Id]),
    case cx_config:get_tenant(binary_to_list(Id)) of
        {ok, Tenant} ->
            JsonTenant = jsx:encode(tenant_to_map(Tenant)),
            {
                ok,
                cowboy_req:reply(
                    200,
                    #{<<"content-type">> => <<"application/json">>},
                    JsonTenant,
                    Req
                ),
                State
            };
        {error, not_found} ->
            {ok, cowboy_req:reply(404, #{}, <<"not found">>, Req), State};
        _ ->
            {ok, cowboy_req:reply(500, #{}, <<"internal server error">>, Req), State}
    end.

% handle_update_tenant(Req, State, Id) ->
%     {ok, Body, Req1} = cowboy_req:read_body(Req),
%     #{<<"name">> := Name} = jsx:decode(Body),
%     case tenant:update_tenant(Id, [{name, Name}]) of
%         {ok, Tenant} ->
%             JsonTenant = jsx:encode(tenant:into_map(Tenant)),
%             {ok,
%                 cowboy_req:reply(
%                     200, #{<<"content-type">> => <<"application/json">>}, JsonTenant, Req1
%                 ),
%                 State};
%         {error, not_found} ->
%             {ok, cowboy_req:reply(404, #{}, <<"not found">>, Req1), State}
%     end.

% handle_delete_tenant(Req, State, Id) ->
%     case tenant:delete_tenant(Id) of
%         {ok, deleted} -> {ok, cowboy_req:reply(204, #{}, [], Req), State};
%         _ -> {ok, cowboy_req:reply(500, #{}, <<"internal server error">>, Req), State}
%     end.

tenant_to_map({cx_record, Id, Name}) ->
    #{id => Id, name => Name};
tenant_to_map(Tenants) when is_list(Tenants) ->
    [#{id => list_to_binary(Id), name => list_to_binary(Name)} || {cx_tenant, Id, Name} <- Tenants].
