-module(cx_handler_userinfo).

%% GET/POST /userinfo — OIDC UserInfo (OIDC Core §5.3). Bearer-protected: the
%% middleware validates the access token and injects #auth_context{}, so a
%% missing/invalid token is already a 401 with a WWW-Authenticate challenge
%% before this runs. Always returns `sub`; adds `email` (the global login
%% identity) and `name` (the tenant user profile) when resolvable. JSON only.

-include_lib("cx_core/include/cx_core.hrl").

-export([init/2]).

init(Req0, Opts = #{context := #auth_context{subject = Subject} = Context}) when
    is_binary(Subject)
->
    Req =
        case cowboy_req:method(Req0) of
            Method when Method =:= <<"GET">>; Method =:= <<"POST">> ->
                Body = cx_json:encode(claims(Context)),
                cowboy_req:reply(
                    200, #{<<"content-type">> => <<"application/json">>}, Body, Req0
                );
            _ ->
                cowboy_req:reply(405, #{<<"allow">> => <<"GET, POST">>}, <<>>, Req0)
        end,
    {ok, Req, Opts};
init(Req0, Opts) ->
    %% A token with no subject cannot identify a user (should not occur — the
    %% verifier requires `sub`).
    {ok, cx_handler:reply({error, no_user}, Req0), Opts}.

claims(#auth_context{subject = Subject, tenant_id = TenantId}) ->
    with_name(with_email(#{<<"sub">> => Subject}, Subject), TenantId, Subject).

%% Login-handle email from the global identity (design §3: distinct from the
%% per-tenant profile email).
with_email(Claims, Subject) ->
    case cx_identity:fetch(Subject) of
        {ok, #cx_identity{email = Email}} when is_binary(Email) ->
            Claims#{<<"email">> => Email};
        _ ->
            Claims
    end.

%% Display name from the tenant user row; a platform admin has no user row, so
%% `name` is simply omitted.
with_name(Claims, TenantId, Subject) ->
    case cx_user:fetch_by_subject(TenantId, Subject) of
        {ok, #cx_user{name = Name}} when is_binary(Name) ->
            Claims#{<<"name">> => Name};
        _ ->
            Claims
    end.
