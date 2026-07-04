-module(cx_routing).

%% The pure functional core of the router. No processes, no Mnesia, no
%% side effects: eligibility and ranking take plain data snapshots and
%% return decisions, so the whole routing semantics is testable (and
%% property-testable) without spawning anything.
%%
%% A snapshot is the map form of one #cx_agent_presence{} row:
%%   #{agent_id, pid, ready, mix, wrapup_until, skills, profile, idle_since}
%% The mix already includes reservations for pending offers.

-include_lib("cx_core/include/cx_core.hrl").

-export([
    can_route/3,
    effective_requirements/2,
    skill_match/2,
    routable/3,
    eligible/4,
    rank/2
]).

-type mix() :: #{binary() => non_neg_integer()}.
-type reqs() :: [{SkillId :: binary(), MinRank :: pos_integer()}].
-type snapshot() :: #{
    agent_id := binary(),
    pid := pid() | undefined,
    ready := #{binary() => ready | {not_ready, binary()}},
    mix := mix(),
    wrapup_until := integer(),
    skills := #{binary() => pos_integer()},
    profile := #cx_routing_profile{},
    idle_since := integer()
}.

-export_type([snapshot/0, mix/0, reqs/0]).

%% Would admitting one more interaction of Media violate the profile?
%% Deny wins: the total cap, the media cap and every triggered guard must
%% all allow it. An empty profile blocks nothing — that is the
%% superhuman/bot/integrator case.
-spec can_route(#cx_routing_profile{}, mix(), binary()) -> boolean().
can_route(
    #cx_routing_profile{
        max_total = MaxTotal,
        media_caps = Caps,
        guards = Guards
    },
    Mix,
    Media
) ->
    Total = lists:sum(maps:values(Mix)),
    TotalOk =
        case MaxTotal of
            unlimited -> true;
            N -> Total + 1 =< N
        end,
    CapOk =
        case Caps of
            #{Media := Cap} -> maps:get(Media, Mix, 0) + 1 =< Cap;
            _ -> true
        end,
    Blocked = lists:any(
        fun(#rp_guard{when_media = W, gte = Gte, block = Block}) ->
            maps:get(W, Mix, 0) >= Gte andalso lists:member(Media, Block)
        end,
        Guards
    ),
    TotalOk andalso CapOk andalso not Blocked.

%% Requirements after waiting WaitedMs: for each skill the last widening
%% step whose after_ms has elapsed replaces the base min_rank. Steps are
%% sorted ascending and non-increasing in rank (validated at config
%% write), so requirements only ever relax as an interaction waits.
-spec effective_requirements([#skill_req{}], non_neg_integer()) -> reqs().
effective_requirements(SkillReqs, WaitedMs) ->
    [
        {S, effective_rank(Base, Widening, WaitedMs)}
     || #skill_req{skill_id = S, min_rank = Base, widening = Widening} <-
            SkillReqs
    ].

effective_rank(Base, Widening, WaitedMs) ->
    case [R || {AfterMs, R} <- Widening, AfterMs =< WaitedMs] of
        [] -> Base;
        Applicable -> lists:last(Applicable)
    end.

%% Ordinal comparison within each skill, nothing else: the agent must hold
%% every required skill at or above the required rank.
-spec skill_match(#{binary() => pos_integer()}, reqs()) -> boolean().
skill_match(AgentSkills, Reqs) ->
    lists:all(
        fun({SkillId, MinRank}) ->
            maps:get(SkillId, AgentSkills, 0) >= MinRank
        end,
        Reqs
    ).

%% The full agent-level gate: ready for the media, not in wrap-up, and
%% the routing profile admits one more of it.
-spec routable(snapshot(), binary(), integer()) -> boolean().
routable(
    #{
        ready := Ready,
        wrapup_until := WrapupUntil,
        mix := Mix,
        profile := Profile
    },
    Media,
    NowMs
) ->
    maps:get(Media, Ready, undefined) =:= ready andalso
        WrapupUntil =< NowMs andalso
        can_route(Profile, Mix, Media).

-spec eligible(binary(), reqs(), [snapshot()], integer()) -> [snapshot()].
eligible(Media, Reqs, Snapshots, NowMs) ->
    [
        S
     || S = #{skills := Skills} <- Snapshots,
        routable(S, Media, NowMs),
        skill_match(Skills, Reqs)
    ].

%% Default ranking: best skills first, then least loaded, then longest
%% idle. Summing ranks across *required* skills is a routing preference
%% between already-eligible agents, not a semantic comparison — ordinal
%% guarantees only ever applied within one skill (in skill_match).
-spec rank(reqs(), [snapshot()]) -> [snapshot()].
rank(Reqs, Candidates) ->
    Keyed = [{sort_key(Reqs, S), S} || S <- Candidates],
    [S || {_, S} <- lists:keysort(1, Keyed)].

sort_key(Reqs, #{skills := Skills, mix := Mix, idle_since := IdleSince}) ->
    SkillScore = lists:sum([maps:get(SkillId, Skills, 0) || {SkillId, _} <- Reqs]),
    Load = lists:sum(maps:values(Mix)),
    {-SkillScore, Load, IdleSince}.
