-module(cx_authorization_code).

%% Single-use authorization codes. Issued by the authorization endpoint (a
%% later change) and redeemed exactly once at the token endpoint: consume/1
%% reads and deletes in one transaction, so a replayed code finds nothing.
%% Short-lived; ram_copies.

-include("cx_core.hrl").

-export([issue/1, consume/1]).

-define(DEFAULT_TTL_S, 60).

%% Args: #{client_id, subject, tenant_id, redirect_uri, code_challenge,
%% code_challenge_method, scope, act_as_tenant?, nonce?}. Returns the code.
-spec issue(map()) -> binary().
issue(Args) ->
    Code = new_code(),
    Now = cx_time:now_ms(),
    Rec = #cx_authorization_code{
        code = Code,
        client_id = maps:get(client_id, Args),
        subject = maps:get(subject, Args),
        tenant_id = maps:get(tenant_id, Args),
        act_as_tenant = maps:get(act_as_tenant, Args, undefined),
        redirect_uri = maps:get(redirect_uri, Args),
        code_challenge = maps:get(code_challenge, Args),
        code_challenge_method = maps:get(code_challenge_method, Args),
        scope = maps:get(scope, Args, []),
        nonce = maps:get(nonce, Args, undefined),
        expires_at = Now + ttl_ms(),
        created_at = Now
    },
    ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
    Code.

%% Redeem exactly once: delete on read, then reject if it had expired.
-spec consume(binary()) ->
    {ok, #cx_authorization_code{}} | {error, invalid | expired}.
consume(Code) ->
    Taken = cx_store:tx(fun() ->
        case mnesia:read(cx_authorization_code, Code) of
            [Rec] ->
                mnesia:delete({cx_authorization_code, Code}),
                {ok, Rec};
            [] ->
                {error, not_found}
        end
    end),
    case Taken of
        {ok, Rec} -> check_expiry(Rec);
        {error, not_found} -> {error, invalid}
    end.

%% ---- internals ----

check_expiry(#cx_authorization_code{expires_at = Exp} = Rec) ->
    case cx_time:now_ms() >= Exp of
        true -> {error, expired};
        false -> {ok, Rec}
    end.

new_code() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

ttl_ms() ->
    cx_config:get(cx_auth, authorization_code_ttl_s, ?DEFAULT_TTL_S) * 1000.
