-module(cx_rest_auth_middleware).

%% Cowboy middleware between router and handler: authenticates the Bearer
%% token and injects #auth_context{} into the handler opts. Handlers never see
%% unauthenticated requests (except cx_handler_health, which bypasses).

-behaviour(cowboy_middleware).

-export([execute/2]).

execute(Req, Env = #{handler := cx_handler_health}) ->
    {ok, Req, Env};
%% WebSocket handshakes cannot carry Authorization from browsers; the
%% socket authenticates in-band (first frame) through the same cx_auth
%% path — see cx_handler_socket.
execute(Req, Env = #{handler := cx_handler_socket}) ->
    {ok, Req, Env};
%% Docs surface (OpenAPI spec + Scalar UI) is public — cowboy_static is only
%% ever routed here (see cx_rest_routes:docs_routes/0). Do not mount a
%% data-serving cowboy_static route without revisiting this bypass.
execute(Req, Env = #{handler := cowboy_static}) ->
    {ok, Req, Env};
%% OpenID Provider discovery + JWKS are public by definition — no token.
execute(Req, Env = #{handler := cx_handler_jwks}) ->
    {ok, Req, Env};
execute(Req, Env = #{handler := cx_handler_oidc_metadata}) ->
    {ok, Req, Env};
%% The token/revoke/introspect endpoints authenticate their own client
%% (Basic / client_secret_post), so no Bearer token is expected.
execute(Req, Env = #{handler := cx_handler_token}) ->
    {ok, Req, Env};
execute(Req, Env = #{handler := cx_handler_revoke}) ->
    {ok, Req, Env};
execute(Req, Env = #{handler := cx_handler_introspect}) ->
    {ok, Req, Env};
%% The authorize endpoint IS the login — it establishes auth, so no token yet.
execute(Req, Env = #{handler := cx_handler_authorize}) ->
    {ok, Req, Env};
%% RP-initiated logout is bound to the provider-session cookie, not a Bearer.
execute(Req, Env = #{handler := cx_handler_logout}) ->
    {ok, Req, Env};
execute(Req, Env = #{handler_opts := Opts}) ->
    %% Read WITHOUT a default so an absent header (undefined) is distinct from
    %% a present-but-invalid one: RFC 6750 §3 says the challenge carries no
    %% `error` when the request had no credentials at all, but `invalid_token`
    %% when a token was supplied and rejected.
    case cowboy_req:header(<<"authorization">>, Req) of
        undefined ->
            {stop, unauthorized(<<"Bearer">>, Req)};
        Authorization ->
            case cx_auth:authenticate(Authorization) of
                {ok, Context} ->
                    {ok, Req, Env#{handler_opts => Opts#{context => Context}}};
                {error, unauthorized} ->
                    {stop, unauthorized(<<"Bearer error=\"invalid_token\"">>, Req)}
            end
    end.

%% 401 with the RFC 9457 problem body and an RFC 6750 WWW-Authenticate challenge.
-spec unauthorized(binary(), cowboy_req:req()) -> cowboy_req:req().
unauthorized(Challenge, Req) ->
    {Status, Body} = cx_handler:problem(unauthorized),
    cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/problem+json">>,
            <<"www-authenticate">> => Challenge
        },
        cx_json:encode(Body),
        Req
    ).
