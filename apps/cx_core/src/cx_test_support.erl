-module(cx_test_support).

%% Shared test plumbing (lives in src/ so other apps' suites can use it;
%% never called by production code). EUnit runs every suite in one VM, so
%% the pg scope may already be running — always tolerate that, and never
%% stop it in a suite's cleanup.

-export([ensure_pg/0]).

-spec ensure_pg() -> pid().
ensure_pg() ->
    case pg:start(cx_event:scope()) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} when is_pid(Pid) -> Pid
    end.
