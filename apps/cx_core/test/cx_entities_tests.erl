-module(cx_entities_tests).

-include_lib("eunit/include/eunit.hrl").
-include("cx_core.hrl").

entities_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun tenant_crud/0,
            fun tenant_explicit_id/0,
            fun tenant_read_own_only/0,
            fun user_crud/0,
            fun user_unknown_references_rejected/0,
            fun delete_blocked_while_referenced/0,
            fun queue_unknown_skill_req_rejected/0,
            fun user_tenant_scoping/0,
            fun user_fetch_by_subject_scoped/0,
            fun role_crud/0,
            fun role_rejects_unassignable_permissions/0,
            fun skill_crud_and_level_validation/0,
            fun queue_crud_and_skill_req_parsing/0,
            fun queue_timeout_defaults_and_infinite_ring/0,
            fun queue_wrapup_policy_validation/0,
            fun routing_profile_crud/0,
            fun not_ready_reason_crud/0,
            fun qualification_code_tree/0,
            fun permission_denied/0,
            fun interaction_indexes_present_and_init_idempotent/0
        ]
    end}.

setup() ->
    %% unique_integer alone restarts per VM and can collide with a stale
    %% dir from an earlier run (whose schema predates record changes) —
    %% the wall clock makes the dir unique across runs too
    Dir =
        "_build/eunit-mnesia-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    ok = cx_db:init(),
    cx_test_support:ensure_pg().

cleanup(_) ->
    stopped = mnesia:stop().

admin(T) -> cx_authz:context(T, [<<"*">>]).

tenant_crud() ->
    Context = cx_authz:context(<<"platform">>, [<<"tenants:admin">>]),
    {ok, #{<<"id">> := Id, <<"name">> := <<"Acme">>, <<"status">> := <<"active">>}} =
        cx_tenant:create(Context, #{<<"name">> => <<"Acme">>}),
    {ok, #{<<"name">> := <<"Acme">>}} = cx_tenant:get(Context, Id),
    {ok, #{<<"status">> := <<"suspended">>}} =
        cx_tenant:update(Context, Id, #{<<"status">> => <<"suspended">>}),
    {ok, List} = cx_tenant:list(Context),
    ?assert(lists:any(fun(#{<<"id">> := I}) -> I =:= Id end, List)),
    ok = cx_tenant:delete(Context, Id),
    ?assertEqual({error, not_found}, cx_tenant:get(Context, Id)).

tenant_explicit_id() ->
    Context = cx_authz:context(<<"platform">>, [<<"tenants:admin">>]),
    {ok, #{<<"id">> := <<"org-123">>}} =
        cx_tenant:create(Context, #{
            <<"name">> => <<"Mapped">>,
            <<"id">> => <<"org-123">>
        }),
    ?assertEqual(
        {error, already_exists},
        cx_tenant:create(Context, #{
            <<"name">> => <<"Dup">>,
            <<"id">> => <<"org-123">>
        })
    ),
    ok = cx_tenant:delete(Context, <<"org-123">>).

tenant_read_own_only() ->
    Admin = cx_authz:context(<<"platform">>, [<<"tenants:admin">>]),
    {ok, #{<<"id">> := Id}} = cx_tenant:create(Admin, #{<<"name">> => <<"Own">>}),
    Member = cx_authz:context(Id, []),
    {ok, #{<<"id">> := Id}} = cx_tenant:get(Member, Id),
    ?assertEqual({error, forbidden}, cx_tenant:get(Member, <<"someone-else">>)),
    ?assertEqual({error, forbidden}, cx_tenant:list(Member)).

user_crud() ->
    T = cx_id:new(),
    Context = admin(T),
    {ok, #{<<"id">> := SkillId}} = cx_skill:create(Context, #{<<"name">> => <<"s1">>}),
    {ok, #{<<"id">> := Id, <<"skills">> := SkillsOut}} =
        cx_user:create(Context, #{
            <<"name">> => <<"Robin">>,
            <<"email">> => <<"r@x.dev">>,
            <<"subject">> => <<"sub-1">>,
            <<"skills">> => [#{<<"skill_id">> => SkillId, <<"rank">> => 3}]
        }),
    %% list-of-objects wire shape survives the round trip
    ?assertEqual([#{<<"skill_id">> => SkillId, <<"rank">> => 3}], SkillsOut),
    {ok, #{<<"email">> := <<"r@x.dev">>}} = cx_user:get(Context, Id),
    {ok, #{<<"status">> := <<"disabled">>}} =
        cx_user:update(Context, Id, #{<<"status">> => <<"disabled">>}),
    ?assertEqual(
        {error, {invalid, <<"skills">>}},
        cx_user:update(Context, Id, #{
            <<"skills">> => [#{<<"skill_id">> => SkillId, <<"rank">> => 0}]
        })
    ),
    %% duplicate skill_ids are rejected, not last-write-wins
    ?assertEqual(
        {error, {invalid, <<"skills">>}},
        cx_user:update(Context, Id, #{
            <<"skills">> => [
                #{<<"skill_id">> => SkillId, <<"rank">> => 1},
                #{<<"skill_id">> => SkillId, <<"rank">> => 2}
            ]
        })
    ),
    {ok, [_]} = cx_user:list(Context),
    ok = cx_user:delete(Context, Id),
    ?assertEqual({error, not_found}, cx_user:get(Context, Id)).

user_unknown_references_rejected() ->
    T = cx_id:new(),
    Context = admin(T),
    Base = #{<<"name">> => <<"X">>, <<"email">> => <<"x@x">>},
    ?assertEqual(
        {error, {invalid, <<"skills">>}},
        cx_user:create(Context, Base#{
            <<"skills">> => [#{<<"skill_id">> => <<"ghost">>, <<"rank">> => 1}]
        })
    ),
    ?assertEqual(
        {error, {invalid, <<"role_ids">>}},
        cx_user:create(Context, Base#{<<"role_ids">> => [<<"ghost">>]})
    ),
    ?assertEqual(
        {error, {invalid, <<"routing_profile_id">>}},
        cx_user:create(Context, Base#{<<"routing_profile_id">> => <<"ghost">>})
    ).

delete_blocked_while_referenced() ->
    T = cx_id:new(),
    Context = admin(T),
    {ok, #{<<"id">> := SkillId}} = cx_skill:create(Context, #{<<"name">> => <<"s">>}),
    {ok, #{<<"id">> := RoleId}} = cx_role:create(Context, #{<<"name">> => <<"r">>}),
    {ok, #{<<"id">> := ProfileId}} =
        cx_routing_profile:create(Context, #{<<"name">> => <<"p">>}),
    {ok, #{<<"id">> := UserId}} =
        cx_user:create(Context, #{
            <<"name">> => <<"U">>,
            <<"email">> => <<"u@x">>,
            <<"skills">> => [#{<<"skill_id">> => SkillId, <<"rank">> => 1}],
            <<"role_ids">> => [RoleId],
            <<"routing_profile_id">> => ProfileId
        }),
    ?assertEqual({error, in_use}, cx_skill:delete(Context, SkillId)),
    ?assertEqual({error, in_use}, cx_role:delete(Context, RoleId)),
    ?assertEqual({error, in_use}, cx_routing_profile:delete(Context, ProfileId)),

    %% queues holding a skill requirement also block the skill
    {ok, #{<<"id">> := QueueId}} =
        cx_queue:create(Context, #{
            <<"name">> => <<"q">>,
            <<"skill_requirements">> => [#{<<"skill_id">> => SkillId, <<"min_rank">> => 1}]
        }),
    ok = cx_user:delete(Context, UserId),
    ?assertEqual({error, in_use}, cx_skill:delete(Context, SkillId)),

    %% once nothing references them, deletes go through
    ok = cx_queue:delete(Context, QueueId),
    ok = cx_skill:delete(Context, SkillId),
    ok = cx_role:delete(Context, RoleId),
    ok = cx_routing_profile:delete(Context, ProfileId).

queue_unknown_skill_req_rejected() ->
    T = cx_id:new(),
    Context = admin(T),
    ?assertEqual(
        {error, {invalid, <<"skill_requirements">>}},
        cx_queue:create(Context, #{
            <<"name">> => <<"q">>,
            <<"skill_requirements">> => [#{<<"skill_id">> => <<"ghost">>, <<"min_rank">> => 1}]
        })
    ).

user_tenant_scoping() ->
    T1 = cx_id:new(),
    T2 = cx_id:new(),
    {ok, #{<<"id">> := Id}} =
        cx_user:create(admin(T1), #{<<"name">> => <<"A">>, <<"email">> => <<"a@x">>}),
    ?assertEqual({error, not_found}, cx_user:get(admin(T2), Id)),
    ?assertEqual({ok, []}, cx_user:list(admin(T2))).

user_fetch_by_subject_scoped() ->
    T1 = cx_id:new(),
    T2 = cx_id:new(),
    Sub = <<"shared-subject">>,
    {ok, #{<<"id">> := Id1}} =
        cx_user:create(admin(T1), #{
            <<"name">> => <<"A">>,
            <<"email">> => <<"a@x">>,
            <<"subject">> => Sub
        }),
    {ok, #cx_user{key = {T1, Id1}}} = cx_user:fetch_by_subject(T1, Sub),
    ?assertEqual({error, not_found}, cx_user:fetch_by_subject(T2, Sub)).

role_crud() ->
    T = cx_id:new(),
    Context = admin(T),
    {ok, #{<<"id">> := Id, <<"permissions">> := [<<"queues:read">>]}} =
        cx_role:create(Context, #{
            <<"name">> => <<"Viewer">>,
            <<"permissions">> => [<<"queues:read">>]
        }),
    NoPerms = cx_authz:context(T, []),
    {ok, #{<<"name">> := <<"Viewer">>}} = cx_role:get(NoPerms, Id),
    {ok, [_]} = cx_role:list(NoPerms),
    ok = cx_role:delete(Context, Id).

%% A tenant admin with roles:write must not be able to grant the
%% platform wildcard, platform-only perms, or unknown strings.
role_rejects_unassignable_permissions() ->
    T = cx_id:new(),
    Context = admin(T),
    Invalid = {error, {invalid, <<"permissions">>}},
    ?assertEqual(
        Invalid,
        cx_role:create(Context, #{<<"name">> => <<"r">>, <<"permissions">> => [<<"*">>]})
    ),
    ?assertEqual(
        Invalid,
        cx_role:create(Context, #{
            <<"name">> => <<"r">>, <<"permissions">> => [<<"tenants:admin">>]
        })
    ),
    ?assertEqual(
        Invalid,
        cx_role:create(Context, #{
            <<"name">> => <<"r">>,
            <<"permissions">> => [<<"queues:read">>, <<"made:up">>]
        })
    ),
    %% update of a valid role cannot smuggle them in either
    {ok, #{<<"id">> := Id}} =
        cx_role:create(Context, #{
            <<"name">> => <<"r">>, <<"permissions">> => [<<"queues:read">>]
        }),
    ?assertEqual(Invalid, cx_role:update(Context, Id, #{<<"permissions">> => [<<"*">>]})),
    ok = cx_role:delete(Context, Id).

skill_crud_and_level_validation() ->
    T = cx_id:new(),
    Context = admin(T),
    Levels = [
        #{<<"rank">> => 2, <<"name">> => <<"expert">>},
        #{<<"rank">> => 1, <<"name">> => <<"trainee">>}
    ],
    {ok, #{<<"id">> := Id, <<"levels">> := Sorted}} =
        cx_skill:create(Context, #{<<"name">> => <<"Permits">>, <<"levels">> => Levels}),
    ?assertEqual(
        [
            #{<<"rank">> => 1, <<"name">> => <<"trainee">>},
            #{<<"rank">> => 2, <<"name">> => <<"expert">>}
        ],
        Sorted
    ),
    ?assertEqual(
        {error, {invalid, <<"levels">>}},
        cx_skill:update(
            Context,
            Id,
            #{
                <<"levels">> => [
                    #{<<"rank">> => 1, <<"name">> => <<"a">>},
                    #{<<"rank">> => 1, <<"name">> => <<"b">>}
                ]
            }
        )
    ),
    ok = cx_skill:delete(Context, Id).

queue_crud_and_skill_req_parsing() ->
    T = cx_id:new(),
    Context = admin(T),
    {ok, #{<<"id">> := S1}} = cx_skill:create(Context, #{<<"name">> => <<"s1">>}),
    Reqs = [
        #{
            <<"skill_id">> => S1,
            <<"min_rank">> => 3,
            <<"widening">> => [
                #{<<"after_ms">> => 60000, <<"min_rank">> => 1},
                #{<<"after_ms">> => 30000, <<"min_rank">> => 2}
            ]
        }
    ],
    {ok, #{<<"id">> := Id, <<"skill_requirements">> := [ParsedReq]}} =
        cx_queue:create(Context, #{
            <<"name">> => <<"Building permits">>,
            <<"skill_requirements">> => Reqs,
            <<"wrapup_duration_ms">> => 5000
        }),
    %% widening comes back sorted by after_ms
    ?assertEqual(
        [
            #{<<"after_ms">> => 30000, <<"min_rank">> => 2},
            #{<<"after_ms">> => 60000, <<"min_rank">> => 1}
        ],
        maps:get(<<"widening">>, ParsedReq)
    ),
    ?assertEqual(
        {error, {invalid, <<"skill_requirements">>}},
        cx_queue:update(
            Context,
            Id,
            #{<<"skill_requirements">> => [#{<<"skill_id">> => <<"s1">>}]}
        )
    ),
    {ok, #{<<"status">> := <<"closed">>}} =
        cx_queue:update(Context, Id, #{<<"status">> => <<"closed">>}),
    ok = cx_queue:delete(Context, Id).

%% Defaults are applied at creation (not record defaults); ring time is
%% integer-only on the wire — 0 means ring forever, garbage is rejected.
queue_timeout_defaults_and_infinite_ring() ->
    T = cx_id:new(),
    Context = admin(T),
    {ok, #{
        <<"id">> := Id,
        <<"offer_timeout_ms">> := 6000,
        <<"wrapup_duration_ms">> := 30000
    }} =
        cx_queue:create(Context, #{<<"name">> => <<"defaults">>}),
    %% 0 = infinite ring; round-trips through update + read
    {ok, #{<<"offer_timeout_ms">> := 0}} =
        cx_queue:update(Context, Id, #{<<"offer_timeout_ms">> => 0}),
    {ok, #{<<"offer_timeout_ms">> := 0}} = cx_queue:get(Context, Id),
    %% and back to a finite value
    {ok, #{<<"offer_timeout_ms">> := 300}} =
        cx_queue:update(Context, Id, #{<<"offer_timeout_ms">> => 300}),
    Invalid = {error, {invalid, <<"offer_timeout_ms">>}},
    ?assertEqual(Invalid, cx_queue:update(Context, Id, #{<<"offer_timeout_ms">> => -1})),
    ?assertEqual(
        Invalid,
        cx_queue:update(Context, Id, #{<<"offer_timeout_ms">> => <<"infinite">>})
    ),
    {ok, #{<<"offer_timeout_ms">> := 0}} =
        cx_queue:create(Context, #{
            <<"name">> => <<"patience">>,
            <<"offer_timeout_ms">> => 0
        }),
    ok = cx_queue:delete(Context, Id).

%% Cross-field wrap-up rules hold on create AND update, on the
%% effective (post-merge) values: mandatory qualification needs a
%% non-zero window to gate in, and the initial grant cannot exceed the
%% total-ACW cap (0 on the wire = uncapped).
queue_wrapup_policy_validation() ->
    T = cx_id:new(),
    Context = admin(T),
    ?assertEqual(
        {error, {invalid, <<"qualification_required">>}},
        cx_queue:create(Context, #{
            <<"name">> => <<"q">>,
            <<"wrapup_duration_ms">> => 0,
            <<"qualification_required">> => true
        })
    ),
    ?assertEqual(
        {error, {invalid, <<"wrapup_duration_ms">>}},
        cx_queue:create(Context, #{
            <<"name">> => <<"q">>,
            <<"wrapup_duration_ms">> => 600000,
            <<"wrapup_max_ms">> => 30000
        })
    ),
    %% uncapped ACW admits any duration
    {ok, #{<<"id">> := Id}} =
        cx_queue:create(Context, #{
            <<"name">> => <<"q">>,
            <<"wrapup_duration_ms">> => 600000,
            <<"wrapup_max_ms">> => 0,
            <<"qualification_required">> => true
        }),
    %% an update flipping ONE side of a valid config is caught on the
    %% merged result
    ?assertEqual(
        {error, {invalid, <<"qualification_required">>}},
        cx_queue:update(Context, Id, #{<<"wrapup_duration_ms">> => 0})
    ),
    ?assertEqual(
        {error, {invalid, <<"wrapup_duration_ms">>}},
        cx_queue:update(Context, Id, #{<<"wrapup_max_ms">> => 30000})
    ),
    {ok, #{<<"qualification_required">> := false, <<"wrapup_duration_ms">> := 0}} =
        cx_queue:update(Context, Id, #{
            <<"qualification_required">> => false,
            <<"wrapup_duration_ms">> => 0
        }),
    ?assertEqual(
        {error, {invalid, <<"qualification_required">>}},
        cx_queue:update(Context, Id, #{<<"qualification_required">> => true})
    ),
    ok = cx_queue:delete(Context, Id).

routing_profile_crud() ->
    T = cx_id:new(),
    Context = admin(T),
    {ok, #{
        <<"id">> := Id,
        <<"max_total">> := 5,
        <<"guards">> := [#{<<"when_media">> := <<"voice">>}]
    }} =
        cx_routing_profile:create(
            Context,
            #{
                <<"name">> => <<"Default">>,
                <<"max_total">> => 5,
                <<"media_capacities">> => #{<<"chat">> => 3},
                <<"guards">> => [
                    #{
                        <<"when_media">> => <<"voice">>,
                        <<"at_least">> => 1,
                        <<"block">> => [<<"chat">>, <<"email">>]
                    }
                ]
            }
        ),
    {ok, #{<<"max_total">> := null}} =
        cx_routing_profile:update(Context, Id, #{<<"max_total">> => null}),
    ?assertEqual(
        {error, {invalid, <<"guards">>}},
        cx_routing_profile:update(
            Context,
            Id,
            #{<<"guards">> => [#{<<"when_media">> => <<"voice">>}]}
        )
    ),
    ok = cx_routing_profile:delete(Context, Id).

not_ready_reason_crud() ->
    T = cx_id:new(),
    Context = admin(T),
    {ok, #{<<"id">> := Id, <<"active">> := true}} =
        cx_not_ready_reason:create(Context, #{<<"name">> => <<"Lunch">>}),
    {ok, #{<<"active">> := false}} =
        cx_not_ready_reason:update(Context, Id, #{<<"active">> => false}),
    NoPerms = cx_authz:context(T, []),
    {ok, [_]} = cx_not_ready_reason:list(NoPerms),
    ok = cx_not_ready_reason:delete(Context, Id).

qualification_code_tree() ->
    T = cx_id:new(),
    Context = admin(T),

    %% a parent must exist
    ?assertEqual(
        {error, {invalid, <<"parent_id">>}},
        cx_qualification_code:create(Context, #{
            <<"name">> => <<"orphan">>,
            <<"parent_id">> => <<"ghost">>
        })
    ),

    {ok, #{<<"id">> := Root, <<"parent_id">> := null, <<"active">> := true}} =
        cx_qualification_code:create(Context, #{<<"name">> => <<"Topic A">>}),
    {ok, #{<<"id">> := Child}} =
        cx_qualification_code:create(Context, #{
            <<"name">> => <<"Topic A.1">>,
            <<"parent_id">> => Root
        }),
    {ok, #{<<"id">> := Grandchild}} =
        cx_qualification_code:create(Context, #{
            <<"name">> => <<"Topic A.1.a">>,
            <<"parent_id">> => Child
        }),

    %% reparenting must not close a loop (root under its own grandchild)
    ?assertEqual(
        {error, {invalid, <<"parent_id">>}},
        cx_qualification_code:update(Context, Root, #{<<"parent_id">> => Grandchild})
    ),
    %% a node is never its own parent
    ?assertEqual(
        {error, {invalid, <<"parent_id">>}},
        cx_qualification_code:update(Context, Child, #{<<"parent_id">> => Child})
    ),

    %% reads are open to tenant members; the tree lists in full
    NoPerms = cx_authz:context(T, []),
    {ok, All} = cx_qualification_code:list(NoPerms),
    ?assertEqual(3, length(All)),

    %% interior nodes with children cannot be deleted...
    ?assertEqual({error, in_use}, cx_qualification_code:delete(Context, Child)),
    %% ...but retire fine, and reparenting to null makes a node a root
    {ok, #{<<"active">> := false}} =
        cx_qualification_code:update(Context, Child, #{<<"active">> => false}),
    {ok, #{<<"parent_id">> := null}} =
        cx_qualification_code:update(Context, Grandchild, #{<<"parent_id">> => null}),

    %% childless now: delete bottom-up
    ok = cx_qualification_code:delete(Context, Grandchild),
    ok = cx_qualification_code:delete(Context, Child),
    ok = cx_qualification_code:delete(Context, Root),
    ?assertEqual({error, not_found}, cx_qualification_code:delete(Context, Root)),
    ok.

permission_denied() ->
    T = cx_id:new(),
    NoPerms = cx_authz:context(T, []),
    ?assertEqual(
        {error, forbidden},
        cx_user:create(NoPerms, #{<<"name">> => <<"x">>, <<"email">> => <<"x@x">>})
    ),
    ?assertEqual({error, forbidden}, cx_user:list(NoPerms)),
    ?assertEqual({error, forbidden}, cx_queue:create(NoPerms, #{<<"name">> => <<"q">>})),
    ?assertEqual({error, forbidden}, cx_queue:list(NoPerms)),
    ?assertEqual({error, forbidden}, cx_skill:create(NoPerms, #{<<"name">> => <<"s">>})),
    ?assertEqual({error, forbidden}, cx_routing_profile:create(NoPerms, #{<<"name">> => <<"p">>})),
    ?assertEqual({error, forbidden}, cx_not_ready_reason:create(NoPerms, #{<<"name">> => <<"r">>})),
    ?assertEqual({error, forbidden}, cx_role:create(NoPerms, #{<<"name">> => <<"r">>})),
    ?assertEqual({error, forbidden}, cx_tenant:create(NoPerms, #{<<"name">> => <<"t">>})).

%% Both interaction secondary indexes exist after init, and a second
%% init over the same data dir is a no-op — pins the already_exists
%% tolerance of both ensure_table and ensure_indexes (an index added to
%% a spec must materialize on pre-existing tables too, or index_read
%% would crash).
interaction_indexes_present_and_init_idempotent() ->
    Indexes =
        case mnesia:table_info(cx_interaction, index) of
            List when is_list(List) -> List
        end,
    ?assert(lists:member(#cx_interaction.queue_key, Indexes)),
    ?assert(lists:member(#cx_interaction.agent_id, Indexes)),
    ok = cx_db:init(),
    ?assertEqual(Indexes, mnesia:table_info(cx_interaction, index)).
