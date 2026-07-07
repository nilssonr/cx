-module(cx_identity).

%% The global person: an email + credential that lives ABOVE tenants (see
%% cx_core.hrl). One identity maps to many cx_user rows — one per tenant —
%% joined by #cx_user.subject; the person authenticates once and picks a
%% tenant (design §3).
%%
%% Two surfaces:
%%   * administration — create/get/list/update/disable — plain domain
%%     functions taking #auth_context{} first, gated by identities:*
%%     (platform-only: provisioning a global person is platform authority);
%%   * authentication — fetch_by_email/verify_credential/tenants_for — carry
%%     NO context. They are the one pre-auth seam (cx_auth calls them at
%%     login, before any identity is established); authorization happens
%%     afterwards, per tenant, through cx_user + cx_authz.

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, disable/2]).
-export([fetch/1, fetch_by_email/1, verify_credential/2, tenants_for/1]).
-export([ensure_seed/1, to_map/1]).

-define(DEFAULT_MAX_FAILURES, 5).
-define(DEFAULT_LOCKOUT_MS, 900000).

%% ---- administration (authorized) ----

create(Context, Params) ->
    maybe
        ok ?= cx_authz:require(Context, <<"identities:write">>),
        {ok, Email} ?= cx_params:require_binary(Params, <<"email">>),
        {ok, Password} ?= cx_params:require_binary(Params, <<"password">>),
        Now = cx_time:now_ms(),
        Rec = #cx_identity{
            subject = cx_id:new(),
            email = Email,
            password_hash = cx_password:hash(Password),
            status = active,
            failed_count = 0,
            created_at = Now,
            updated_at = Now
        },
        ok ?= write_unique(Rec),
        {ok, to_map(Rec)}
    end.

get(Context, Subject) ->
    maybe
        ok ?= cx_authz:require(Context, <<"identities:read">>),
        {ok, Rec} ?= cx_store:read(cx_identity, Subject),
        {ok, to_map(Rec)}
    end.

list(Context) ->
    maybe
        ok ?= cx_authz:require(Context, <<"identities:read">>),
        Recs = cx_store:list(cx_identity, cx_patterns:identities()),
        {ok, [to_map(R) || R <- Recs]}
    end.

update(Context, Subject, Params) ->
    maybe
        ok ?= cx_authz:require(Context, <<"identities:write">>),
        {ok, Rec0} ?= cx_store:read(cx_identity, Subject),
        {ok, Email} ?= cx_params:optional_binary(Params, <<"email">>, Rec0#cx_identity.email),
        {ok, Status} ?=
            cx_params:optional_atom(
                Params, <<"status">>, [active, disabled], Rec0#cx_identity.status
            ),
        Rec = Rec0#cx_identity{
            email = Email,
            status = Status,
            password_hash = new_hash(Params, Rec0#cx_identity.password_hash),
            updated_at = cx_time:now_ms()
        },
        ok ?= write_unique(Rec),
        {ok, to_map(Rec)}
    end.

disable(Context, Subject) ->
    maybe
        ok ?= cx_authz:require(Context, <<"identities:write">>),
        {ok, Rec0} ?= cx_store:read(cx_identity, Subject),
        Rec = Rec0#cx_identity{status = disabled, updated_at = cx_time:now_ms()},
        ok ?= write(Rec),
        ok
    end.

%% ---- authentication (pre-auth, no context) ----

-spec fetch(binary()) -> {ok, #cx_identity{}} | {error, not_found}.
fetch(Subject) ->
    cx_store:read(cx_identity, Subject).

%% Email is globally unique (enforced at write), so at most one row.
-spec fetch_by_email(binary()) -> {ok, #cx_identity{}} | {error, not_found}.
fetch_by_email(Email) ->
    case cx_store:dirty_index_read(cx_identity, Email, #cx_identity.email) of
        [Rec | _] -> {ok, Rec};
        [] -> {error, not_found}
    end.

%% Login credential check. Always runs one derivation (real or dummy) so an
%% unknown email is indistinguishable in time from a wrong password.
%% Failures increment a per-identity counter and lock the account after a
%% threshold; a success resets it.
-spec verify_credential(binary(), binary()) ->
    {ok, binary()} | {error, invalid_credentials | disabled | locked}.
verify_credential(Email, Password) ->
    case fetch_by_email(Email) of
        {error, not_found} ->
            _ = cx_password:verify_dummy(Password),
            {error, invalid_credentials};
        {ok, #cx_identity{status = disabled}} ->
            {error, disabled};
        {ok, Identity = #cx_identity{locked_until = LockedUntil}} when is_integer(LockedUntil) ->
            case cx_time:now_ms() < LockedUntil of
                true -> {error, locked};
                false -> check_password(Identity, Password)
            end;
        {ok, Identity} ->
            check_password(Identity, Password)
    end.

%% Every tenant this person belongs to = the tenants whose cx_user rows
%% carry this subject. This is the tenant-picker set (design §9.1).
-spec tenants_for(binary()) -> [binary()].
tenants_for(Subject) ->
    Rows = cx_store:dirty_index_read(cx_user, Subject, #cx_user.subject),
    lists:usort([T || #cx_user{key = {T, _}, status = active} <- Rows]).

%% ---- boot seed (idempotent, no authz) ----

%% Seed a local admin identity at boot if absent (design §10). No context:
%% a fresh deployment has no admin to authorize the write. The subject must
%% also be listed in cx_auth platform_admin_subjects to gain platform
%% authority — the identity holds the credential, the config grants the
%% power.
-spec ensure_seed(map()) -> ok.
ensure_seed(#{subject := Subject, email := Email, password := Password}) when
    is_binary(Subject), is_binary(Email), is_binary(Password)
->
    Now = cx_time:now_ms(),
    _ = cx_store:tx(fun() ->
        case mnesia:read(cx_identity, Subject) of
            [] ->
                mnesia:write(#cx_identity{
                    subject = Subject,
                    email = Email,
                    password_hash = cx_password:hash(Password),
                    status = active,
                    failed_count = 0,
                    created_at = Now,
                    updated_at = Now
                });
            [_] ->
                ok
        end
    end),
    ok;
ensure_seed(_) ->
    ok.

%% Never expose password_hash / lockout state on the wire.
-spec to_map(#cx_identity{}) -> map().
to_map(#cx_identity{
    subject = Subject,
    email = Email,
    status = Status,
    created_at = CreatedAt,
    updated_at = UpdatedAt
}) ->
    #{
        <<"subject">> => Subject,
        <<"email">> => Email,
        <<"status">> => atom_to_binary(Status),
        <<"created_at">> => CreatedAt,
        <<"updated_at">> => UpdatedAt
    }.

%% ---- internals ----

new_hash(#{<<"password">> := Password}, _Old) when is_binary(Password), Password =/= <<>> ->
    cx_password:hash(Password);
new_hash(_Params, Old) ->
    Old.

check_password(#cx_identity{password_hash = undefined}, Password) ->
    %% federated identity (v2): no local credential, never local-auth
    _ = cx_password:verify_dummy(Password),
    {error, invalid_credentials};
check_password(Identity = #cx_identity{subject = Subject, password_hash = Hash}, Password) ->
    case cx_password:verify(Password, Hash) of
        true ->
            ok = record_success(Identity),
            {ok, Subject};
        false ->
            ok = record_failure(Identity),
            {error, invalid_credentials}
    end.

record_success(#cx_identity{failed_count = 0, locked_until = undefined}) ->
    %% clean already — skip the write on the hot success path
    ok;
record_success(Identity) ->
    write(Identity#cx_identity{
        failed_count = 0, locked_until = undefined, updated_at = cx_time:now_ms()
    }).

record_failure(Identity = #cx_identity{failed_count = Failed}) ->
    Max = cx_config:get(cx_core, login_max_failures, ?DEFAULT_MAX_FAILURES),
    Count = Failed + 1,
    LockedUntil =
        case Count >= Max of
            true ->
                cx_time:now_ms() + cx_config:get(cx_core, login_lockout_ms, ?DEFAULT_LOCKOUT_MS);
            false ->
                undefined
        end,
    write(Identity#cx_identity{
        failed_count = Count, locked_until = LockedUntil, updated_at = cx_time:now_ms()
    }).

%% Email uniqueness is enforced here, in the write transaction (Mnesia does
%% not enforce unique secondary indexes), same pattern as cx_user.
write_unique(Rec = #cx_identity{subject = Subject, email = Email}) ->
    cx_store:tx(fun() ->
        Clashes = [
            S
         || #cx_identity{subject = S} <- mnesia:index_read(cx_identity, Email, #cx_identity.email),
            S =/= Subject
        ],
        case Clashes of
            [] -> mnesia:write(Rec);
            _ -> {error, already_exists}
        end
    end).

write(Rec) ->
    cx_store:tx(fun() -> mnesia:write(Rec) end).
