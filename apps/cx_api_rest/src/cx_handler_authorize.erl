-module(cx_handler_authorize).

%% GET/POST /authorize — the interactive OAuth authorization endpoint and cx's
%% hosted login. Auth-exempt (it establishes auth). It validates the client +
%% redirect_uri + PKCE, authenticates the person (or resumes a provider
%% session), lets them pick a tenant, and redirects back to the client with a
%% single-use code. Grant/token logic stays in cx_oauth/cx_authorization_code;
%% this handler is transport + the login UI.
%%
%% A bad client_id or redirect_uri renders an error page (never redirects to
%% an unvalidated URI); other errors redirect back with ?error=. The authorize
%% request is carried across the login and tenant-select forms as hidden
%% fields; CSRF is a double-submit cookie + hidden field.

-include_lib("cx_core/include/cx_core.hrl").

-export([init/2]).

-define(CARRIED, [
    <<"client_id">>,
    <<"redirect_uri">>,
    <<"state">>,
    <<"scope">>,
    <<"code_challenge">>,
    <<"code_challenge_method">>,
    <<"nonce">>,
    <<"response_type">>
]).

init(Req0, Opts) ->
    Req =
        case cowboy_req:method(Req0) of
            <<"GET">> -> get_authorize(Req0);
            <<"POST">> -> post_authorize(Req0);
            _ -> reply_html(405, cx_login_html:error_page(<<"Method not allowed">>), Req0)
        end,
    {ok, Req, Opts}.

%% ---- GET ----

get_authorize(Req0) ->
    Params = maps:from_list(cowboy_req:parse_qs(Req0)),
    case validate(Params) of
        {ok, _Client, AuthReq} ->
            case session_from_cookie(Req0) of
                {ok, Session} -> proceed(subject(Session), id(Session), AuthReq, Req0);
                none -> render_login(AuthReq, undefined, Req0)
            end;
        {render, Message} ->
            reply_html(400, cx_login_html:error_page(Message), Req0);
        {redirect, Uri, State, Code} ->
            redirect_error(Uri, State, Code, Req0)
    end.

%% ---- POST ----

post_authorize(Req0) ->
    {ok, Form, Req1} = cowboy_req:read_urlencoded_body(Req0),
    Params = maps:from_list(Form),
    case check_csrf(Params, Req1) of
        ok ->
            case maps:get(<<"step">>, Params, <<"login">>) of
                <<"select_tenant">> -> post_select_tenant(Params, Req1);
                _ -> post_login(Params, Req1)
            end;
        error ->
            reply_html(400, cx_login_html:error_page(<<"Invalid or expired form.">>), Req1)
    end.

post_login(Params, Req) ->
    case validate(Params) of
        {ok, _Client, AuthReq} ->
            case
                cx_identity:verify_credential(
                    maps:get(<<"email">>, Params, <<>>), maps:get(<<"password">>, Params, <<>>)
                )
            of
                {ok, Subject} ->
                    Remember = maps:get(<<"remember_me">>, Params, undefined) =:= <<"1">>,
                    {SessionId, _} = cx_provider_session:create(Subject, Remember),
                    Req1 = set_session_cookie(SessionId, Remember, Req),
                    proceed(Subject, SessionId, AuthReq, Req1);
                {error, _} ->
                    render_login(AuthReq, <<"Invalid email or password.">>, Req)
            end;
        {render, Message} ->
            reply_html(400, cx_login_html:error_page(Message), Req);
        {redirect, Uri, State, Code} ->
            redirect_error(Uri, State, Code, Req)
    end.

post_select_tenant(Params, Req) ->
    case {validate(Params), session_from_cookie(Req)} of
        {{ok, _Client, AuthReq}, {ok, Session}} ->
            Subject = subject(Session),
            Chosen = maps:get(<<"tenant_id">>, Params, undefined),
            case allowed_tenant(Subject, Chosen) of
                {ok, PlatformAdmin} ->
                    issue_code_redirect(
                        AuthReq, Subject, Chosen, act_as(PlatformAdmin, Chosen), id(Session), Req
                    );
                false ->
                    reply_html(403, cx_login_html:error_page(<<"Invalid tenant.">>), Req)
            end;
        {{render, Message}, _} ->
            reply_html(400, cx_login_html:error_page(Message), Req);
        {{redirect, Uri, State, Code}, _} ->
            redirect_error(Uri, State, Code, Req);
        {_, none} ->
            reply_html(
                403, cx_login_html:error_page(<<"Session expired. Please sign in again.">>), Req
            )
    end.

%% ---- tenant resolution + code issuance ----

%% Resume/continue after authentication: single tenant -> silent code;
%% several -> tenant picker; none -> error.
proceed(Subject, SessionId, AuthReq, Req) ->
    case resolve_tenants(Subject) of
        {error, no_tenant} ->
            reply_html(403, cx_login_html:error_page(<<"No tenant access.">>), Req);
        {ok, PlatformAdmin, [{TenantId, _Name}]} ->
            issue_code_redirect(
                AuthReq, Subject, TenantId, act_as(PlatformAdmin, TenantId), SessionId, Req
            );
        {ok, _PlatformAdmin, Tenants} ->
            render_picker(AuthReq, Tenants, Req)
    end.

%% Platform admins see every tenant plus a "Platform administration" option
%% (a reserved id for platform ops / bootstrapping the first tenant); normal
%% users see the tenants they belong to.
-spec resolve_tenants(binary()) -> {ok, boolean(), [{binary(), binary()}]} | {error, no_tenant}.
resolve_tenants(Subject) ->
    case is_platform_admin(Subject) of
        true ->
            {ok, true, [{<<"platform">>, <<"Platform administration">>} | all_tenants()]};
        false ->
            case [{Id, tenant_name(Id)} || Id <- cx_identity:tenants_for(Subject)] of
                [] -> {error, no_tenant};
                Tenants -> {ok, false, Tenants}
            end
    end.

allowed_tenant(Subject, Chosen) when is_binary(Chosen) ->
    case resolve_tenants(Subject) of
        {error, no_tenant} ->
            false;
        {ok, PlatformAdmin, Tenants} ->
            case lists:keymember(Chosen, 1, Tenants) of
                true -> {ok, PlatformAdmin};
                false -> false
            end
    end;
allowed_tenant(_Subject, _Chosen) ->
    false.

%% Platform admins mark the acting tenant with act_as_tenant; normal users don't.
act_as(true, TenantId) -> TenantId;
act_as(false, _TenantId) -> undefined.

is_platform_admin(Subject) ->
    lists:member(Subject, cx_config:get(cx_auth, platform_admin_subjects, [])).

all_tenants() ->
    [
        {T#cx_tenant.id, T#cx_tenant.name}
     || T <- cx_store:list(cx_tenant, cx_patterns:tenants())
    ].

tenant_name(Id) ->
    case cx_store:read(cx_tenant, Id) of
        {ok, #cx_tenant{name = Name}} -> Name;
        {error, not_found} -> Id
    end.

issue_code_redirect(AuthReq, Subject, TenantId, ActAsTenant, SessionId, Req) ->
    Code = cx_authorization_code:issue(#{
        client_id => maps:get(<<"client_id">>, AuthReq),
        subject => Subject,
        tenant_id => TenantId,
        act_as_tenant => ActAsTenant,
        session_id => SessionId,
        redirect_uri => maps:get(<<"redirect_uri">>, AuthReq),
        code_challenge => maps:get(<<"code_challenge">>, AuthReq),
        code_challenge_method => maps:get(<<"code_challenge_method">>, AuthReq),
        scope => scope_list(maps:get(<<"scope">>, AuthReq, <<>>)),
        nonce => maps:get(<<"nonce">>, AuthReq, undefined)
    }),
    Location = redirect_with(
        maps:get(<<"redirect_uri">>, AuthReq),
        with_state(
            [{<<"code">>, Code}, {<<"iss">>, issuer()}], maps:get(<<"state">>, AuthReq, undefined)
        )
    ),
    redirect(Location, Req).

redirect_error(Uri, State, ErrorCode, Req) ->
    Location = redirect_with(
        Uri, with_state([{<<"error">>, atom_to_binary(ErrorCode)}, {<<"iss">>, issuer()}], State)
    ),
    redirect(Location, Req).

with_state(Query, State) when is_binary(State) -> [{<<"state">>, State} | Query];
with_state(Query, _State) -> Query.

redirect_with(Uri, Query) ->
    Separator =
        case binary:match(Uri, <<"?">>) of
            nomatch -> <<"?">>;
            _ -> <<"&">>
        end,
    <<Uri/binary, Separator/binary, (query_string(Query))/binary>>.

%% compose_query returns iodata for valid input (ours always is); the error
%% branch is unreachable but keeps the type honest.
query_string(Query) ->
    case uri_string:compose_query(Query) of
        {error, _, _} -> <<>>;
        Encoded -> iolist_to_binary(Encoded)
    end.

%% ---- request validation ----

-spec validate(map()) ->
    {ok, #cx_oauth_client{}, map()}
    | {render, binary()}
    | {redirect, binary(), binary() | undefined, atom()}.
validate(Params) ->
    maybe
        {ok, Client} ?= validate_client(Params),
        {ok, RedirectUri} ?= validate_redirect(Params, Client),
        ok ?= check(response_type_ok(Params), RedirectUri, Params, unsupported_response_type),
        ok ?= check(pkce_ok(Params), RedirectUri, Params, invalid_request),
        ok ?= check(scope_ok(Params, Client), RedirectUri, Params, invalid_scope),
        {ok, Client, maps:with(?CARRIED, Params)}
    end.

validate_client(Params) ->
    case maps:get(<<"client_id">>, Params, undefined) of
        ClientId when is_binary(ClientId) ->
            case cx_oauth_client:fetch(ClientId) of
                {ok, Client} -> {ok, Client};
                {error, not_found} -> {render, <<"Unknown client.">>}
            end;
        _ ->
            {render, <<"Missing client_id.">>}
    end.

validate_redirect(Params, #cx_oauth_client{redirect_uris = Uris}) ->
    case maps:get(<<"redirect_uri">>, Params, undefined) of
        Uri when is_binary(Uri) ->
            case lists:member(Uri, Uris) of
                true -> {ok, Uri};
                false -> {render, <<"Invalid redirect_uri.">>}
            end;
        _ ->
            {render, <<"Missing redirect_uri.">>}
    end.

check(true, _Uri, _Params, _Code) -> ok;
check(false, Uri, Params, Code) -> {redirect, Uri, maps:get(<<"state">>, Params, undefined), Code}.

response_type_ok(Params) ->
    maps:get(<<"response_type">>, Params, undefined) =:= <<"code">>.

pkce_ok(Params) ->
    is_binary(maps:get(<<"code_challenge">>, Params, undefined)) andalso
        maps:get(<<"code_challenge_method">>, Params, undefined) =:= <<"S256">>.

scope_ok(Params, #cx_oauth_client{scopes = Allowed}) ->
    lists:all(
        fun(Scope) -> lists:member(Scope, Allowed) end,
        scope_list(maps:get(<<"scope">>, Params, <<>>))
    ).

%% ---- sessions + cookies ----

session_from_cookie(Req) ->
    case lists:keyfind(<<"cx_session">>, 1, cowboy_req:parse_cookies(Req)) of
        {_, SessionId} ->
            case cx_provider_session:fetch(SessionId) of
                {ok, Session} ->
                    _ = cx_provider_session:touch(Session),
                    {ok, Session};
                {error, _} ->
                    none
            end;
        false ->
            none
    end.

set_session_cookie(SessionId, Remember, Req) ->
    MaxAge =
        case Remember of
            true -> cx_config:get(cx_auth, session_remember_ttl_s, 2592000);
            false -> undefined
        end,
    cowboy_req:set_resp_cookie(<<"cx_session">>, SessionId, Req, cookie_opts(MaxAge)).

render_login(AuthReq, Error, Req) ->
    {Csrf, Req1} = fresh_csrf(Req),
    reply_html(200, cx_login_html:login_page(AuthReq, Csrf, Error), Req1).

render_picker(AuthReq, Tenants, Req) ->
    {Csrf, Req1} = fresh_csrf(Req),
    reply_html(200, cx_login_html:tenant_picker(AuthReq, Csrf, Tenants), Req1).

fresh_csrf(Req) ->
    Token = base64:encode(crypto:strong_rand_bytes(24), #{mode => urlsafe, padding => false}),
    {Token, cowboy_req:set_resp_cookie(<<"cx_csrf">>, Token, Req, cookie_opts(undefined))}.

check_csrf(Params, Req) ->
    Form = maps:get(<<"csrf">>, Params, undefined),
    Cookie =
        case lists:keyfind(<<"cx_csrf">>, 1, cowboy_req:parse_cookies(Req)) of
            {_, Value} -> Value;
            false -> undefined
        end,
    case is_binary(Form) andalso Form =:= Cookie of
        true -> ok;
        false -> error
    end.

cookie_opts(MaxAge) ->
    Base = #{http_only => true, secure => cookie_secure(), same_site => lax, path => <<"/">>},
    case MaxAge of
        undefined -> Base;
        Seconds -> Base#{max_age => Seconds}
    end.

%% https-only cookies in production; the allow_insecure_jwks dev flag (plain
%% http localhost) also relaxes this so cookies work in dev/test.
cookie_secure() ->
    cx_config:get(cx_auth, allow_insecure_jwks, false) =/= true.

%% ---- small helpers ----

subject(Session) -> Session#cx_provider_session.subject.
id(Session) -> Session#cx_provider_session.id.

issuer() -> cx_config:get(cx_auth, issuer, <<>>).

scope_list(Bin) when is_binary(Bin) ->
    [Scope || Scope <- binary:split(Bin, <<" ">>, [global]), Scope =/= <<>>];
scope_list(_) ->
    [].

reply_html(Status, Body, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"text/html; charset=utf-8">>}, Body, Req).

redirect(Location, Req) ->
    cowboy_req:reply(302, #{<<"location">> => Location}, <<>>, Req).
