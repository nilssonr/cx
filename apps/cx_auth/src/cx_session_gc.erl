-module(cx_session_gc).

%% Periodic sweep of expired provider sessions. Session expiry is enforced on
%% read (cx_provider_session:fetch); this only reclaims dead disc rows so they
%% don't accumulate. Started with the local issuer (cx_auth_sup).

-behaviour(gen_server).

-include_lib("cx_core/include/cx_core.hrl").

-export([start_link/0, sweep/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DEFAULT_INTERVAL_MS, 300000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Sweep now, returning the number of sessions reclaimed (used by tests).
-spec sweep() -> non_neg_integer().
sweep() ->
    gen_server:call(?MODULE, sweep).

init([]) ->
    schedule(),
    {ok, #{}}.

handle_call(sweep, _From, State) ->
    {reply, do_sweep(), State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    _ = do_sweep(),
    schedule(),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%% ---- internals ----

schedule() ->
    Interval = cx_config:get(cx_auth, session_gc_interval_ms, ?DEFAULT_INTERVAL_MS),
    erlang:send_after(Interval, self(), sweep).

do_sweep() ->
    Now = cx_time:now_ms(),
    Expired = [
        R
     || R <- cx_store:list(cx_provider_session, cx_patterns:provider_sessions()),
        is_expired(R, Now)
    ],
    ok = cx_store:tx(fun() ->
        lists:foreach(
            fun(R) -> mnesia:delete({cx_provider_session, R#cx_provider_session.id}) end, Expired
        )
    end),
    length(Expired).

is_expired(#cx_provider_session{idle_expires_at = Idle, absolute_expires_at = Absolute}, Now) ->
    Now >= Idle orelse Now >= Absolute.
