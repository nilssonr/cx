-module(cx_presence_session_sup).

%% Presence sessions are temporary: a crashed session is NOT restarted
%% by the supervisor — the surviving connection processes re-register
%% (their monitors fire) and rebuild it from the durable declared layer
%% plus their own live existence. The connections ARE the recovery.

-behaviour(supervisor).

-export([start_link/0, start_session/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_session(TenantId, UserId) ->
    supervisor:start_child(?MODULE, [TenantId, UserId]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    ChildSpecs = [
        #{
            id => cx_presence_session,
            start => {cx_presence_session, start_link, []},
            restart => temporary
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
