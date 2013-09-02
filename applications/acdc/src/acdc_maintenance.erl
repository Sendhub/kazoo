%%%-------------------------------------------------------------------
%%% @copyright (C) 2013, 2600Hz
%%% @doc
%%% Helpers for cli commands
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(acdc_maintenance).

-export([current_calls/1, current_calls/2
         ,current_statuses/1

         ,queues_summary/0, queues_summary/1, queue_summary/2
         ,queues_detail/0, queues_detail/1, queue_detail/2
         ,queues_restart/1, queue_restart/2

         ,agents_summary/0, agents_summary/1, agent_summary/2
         ,agents_detail/0, agents_detail/1, agent_detail/2
         ,agent_login/2
         ,agent_logout/2
         ,agent_pause/2, agent_pause/3
         ,agent_resume/2
         ,agent_queue_login/3
         ,agent_queue_logout/3
        ]).

-include("acdc.hrl").

-define(KEYS, [<<"Waiting">>, <<"Handled">>, <<"Processed">>, <<"Abandoned">>]).

-spec current_statuses(ne_binary()) -> 'ok'.
current_statuses(AcctId) ->
    put('callid', ?MODULE),
    {'ok', Agents} = acdc_agent_util:most_recent_statuses(AcctId),
    case wh_json:get_values(Agents) of
        {[], []} ->
            lager:info("No agent statuses found for ~s", [AcctId]);
        {As, _} ->
            lager:info("Agent Statuses for ~s", [AcctId]),
            lager:info("~4s | ~35s | ~12s | ~20s |", [<<>>, <<"Agent-ID">>, <<"Status">>, <<"Timestamp">>]),
            log_current_statuses(As, 1)
    end,
    'ok'.

log_current_statuses([], _) -> 'ok';
log_current_statuses([A|As], N) ->
    log_current_status(A, N),
    log_current_statuses(As, N+1).

log_current_status(A, N) ->
    lager:info("~4b | ~35s | ~12s | ~20s |", [N, wh_json:get_value(<<"agent_id">>, A)
                                               ,wh_json:get_value(<<"status">>, A)
                                               ,wh_util:pretty_print_datetime(wh_json:get_integer_value(<<"timestamp">>, A))
                                              ]).

current_calls(AcctId) ->
    put('callid', ?MODULE),
    Req = [{<<"Account-ID">>, AcctId}
           | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    get_and_show(AcctId, <<"all">>, Req).

current_calls(AcctId, QueueId) when is_binary(QueueId) ->
    put('callid', ?MODULE),
    Req = [{<<"Account-ID">>, AcctId}
           ,{<<"Queue-ID">>, QueueId}
           | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    get_and_show(AcctId, QueueId, Req);
current_calls(AcctId, Props) ->
    put('callid', ?MODULE),
    Req = [{<<"Account-ID">>, AcctId}
           | Props ++ wh_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    get_and_show(AcctId, <<"custom">>, Req).

get_and_show(AcctId, QueueId, Req) ->
    put('callid', <<"acdc_maint.", AcctId/binary, ".", QueueId/binary>>),
    case whapps_util:amqp_pool_collect(Req, fun wapi_acdc_stats:publish_current_calls_req/1) of
        {_, []} ->
            lager:info("no call stats returned for account ~s (queue ~s)", [AcctId, QueueId]);
        {'ok', JObjs} ->
            lager:info("call stats for account ~s (queue ~s)", [AcctId, QueueId]),
            show_call_stats(JObjs, ?KEYS);
        {'timeout', JObjs} ->
            lager:info("call stats for account ~s (queue ~s)", [AcctId, QueueId]),
            show_call_stats(JObjs, ?KEYS);
        {'error', _E} ->
            lager:info("failed to lookup call stats for account ~s (queue ~s): ~p", [AcctId, QueueId, _E])
    end.

show_call_stats([], _) -> 'ok';
show_call_stats([Resp|Resps], Ks) ->
    put('callid', ?MODULE),
    show_call_stat_cat(Ks, Resp),
    show_call_stats(Resps, Ks).

show_call_stat_cat([], _) -> 'ok';
show_call_stat_cat([K|Ks], Resp) ->
    case wh_json:get_value(K, Resp) of
        'undefined' -> show_call_stat_cat(Ks, Resp);
        V ->
            lager:info("call stats in ~s", [K]),
            show_stats(V),
            show_call_stat_cat(Ks, Resp)
    end.

show_stats([]) -> 'ok';
show_stats([S|Ss]) ->
    _ = [lager:info("~s: ~p", [K, V])
         || {K, V} <- wh_json:to_proplist(wh_doc:public_fields(S))
        ],
    show_stats(Ss).

-spec queues_summary() -> 'ok'.
-spec queues_summary(ne_binary()) -> 'ok'.
-spec queue_summary(ne_binary(), ne_binary()) -> 'ok'.
queues_summary() ->
    put('callid', ?MODULE),
    show_queues_summary(acdc_queues_sup:queues_running()).

queues_summary(AcctId) ->
    put('callid', ?MODULE),
    show_queues_summary(
      [Q || {_, {QAcctId, _}} = Q <- acdc_queues_sup:queues_running(),
            QAcctId =:= AcctId
      ]).

queue_summary(AcctId, QueueId) ->
    put('callid', ?MODULE),
    show_queues_summary(
      [Q || {_, {QAcctId, QQueueId}} = Q <- acdc_queues_sup:queues_running(),
            QAcctId =:= AcctId,
            QQueueId =:= QueueId
      ]).

-spec show_queues_summary([{pid(), {ne_binary(), ne_binary()}},...] | []) -> 'ok'.
show_queues_summary([]) -> 'ok';
show_queues_summary([{P, {AcctId, QueueId}}|Qs]) ->
    lager:info("  Supervisor: ~p Acct: ~s Queue: ~s~n", [P, AcctId, QueueId]),
    show_queues_summary(Qs).

queues_detail() ->
    put('callid', ?MODULE),
    acdc_queues_sup:status().
queues_detail(AcctId) ->
    put('callid', ?MODULE),
    [acdc_queue_sup:status(S)
     || S <- acdc_queues_sup:find_acct_supervisors(AcctId)
    ],
    'ok'.
queue_detail(AcctId, QueueId) ->
    put('callid', ?MODULE),
    case acdc_queues_sup:find_queue_supervisor(AcctId, QueueId) of
        'undefined' -> lager:info("no queue ~s in account ~s", [QueueId, AcctId]);
        Pid -> acdc_queue_sup:status(Pid)
    end.

queues_restart(AcctId) ->
    put('callid', ?MODULE),
    case acdc_queues_sup:find_acct_supervisors(AcctId) of
        [] ->
            lager:info("there are no running queues in ~s", [AcctId]);
        Pids ->
            [maybe_stop_then_start_queue(AcctId, Pid) || Pid <- Pids]
    end.
queue_restart(AcctId, QueueId) ->
    put('callid', ?MODULE),
    case acdc_queues_sup:find_queue_supervisor(AcctId, QueueId) of
        'undefined' ->
            lager:info("queue ~s in account ~s not running", [QueueId, AcctId]);
        Pid ->
            maybe_stop_then_start_queue(AcctId, QueueId, Pid)
    end.

-spec maybe_stop_then_start_queue(ne_binary(), pid()) -> 'ok'.
-spec maybe_stop_then_start_queue(ne_binary(), ne_binary(), pid()) -> 'ok'.

maybe_stop_then_start_queue(AcctId, Pid) ->
    {AcctId, QueueId} = acdc_queue_manager:config(acdc_queue_sup:manager(Pid)),
    maybe_stop_then_start_queue(AcctId, QueueId, Pid).
maybe_stop_then_start_queue(AcctId, QueueId, Pid) ->
    case supervisor:terminate_child('acdc_queues_sup', Pid) of
        'ok' ->
            lager:info("stopped queue supervisor ~p", [Pid]),
            maybe_start_queue(AcctId, QueueId);
        {'error', 'not_found'} ->
            lager:info("queue supervisor ~p not found", [Pid]);
        {'error', _E} ->
            lager:info("failed to terminate queue supervisor ~p: ~p", [_E])
    end.

maybe_start_queue(AcctId, QueueId) ->
    case acdc_queues_sup:new(AcctId, QueueId) of
        {'ok', 'undefined'} ->
            lager:info("tried to start queue but it asked to be ignored");
        {'ok', Pid} ->
            lager:info("started queue back up in ~p", [Pid]);
        {'error', 'already_present'} ->
            lager:info("queue is already present (but not running)");
        {'error', {'already_running', Pid}} ->
            lager:info("queue is already running in ~p", [Pid]);
        {'error', _E} ->
            lager:info("failed to start queue: ~p", [_E])
    end.

agents_summary() ->
    put('callid', ?MODULE),
    show_agents_summary(acdc_agents_sup:agents_running()).

agents_summary(AcctId) ->
    put('callid', ?MODULE),
    show_agents_summary(
      [A || {_, {AAcctId, _, _}} = A <- acdc_agents_sup:agents_running(),
            AAcctId =:= AcctId
      ]).

agent_summary(AcctId, AgentId) ->
    put('callid', ?MODULE),
    show_agents_summary(
      [Q || {_, {AAcctId, AAgentId, _}} = Q <- acdc_agents_sup:agents_running(),
            AAcctId =:= AcctId,
            AAgentId =:= AgentId
      ]).

-spec show_agents_summary([{pid(), acdc_agent:config()},...] | []) -> 'ok'.
show_agents_summary([]) -> 'ok';
show_agents_summary([{P, {AcctId, QueueId, _AMQPQueue}}|Qs]) ->
    lager:info("  Supervisor: ~p Acct: ~s Agent: ~s", [P, AcctId, QueueId]),
    show_queues_summary(Qs).

agents_detail() ->
    put('callid', ?MODULE),
    acdc_agents_sup:status().
agents_detail(AcctId) ->
    put('callid', ?MODULE),
    [acdc_agent_sup:status(S)
     || S <- acdc_agents_sup:find_acct_supervisors(AcctId)
    ],
    'ok'.
agent_detail(AcctId, AgentId) ->
    put('callid', ?MODULE),
    case acdc_agents_sup:find_agent_supervisor(AcctId, AgentId) of
        'undefined' -> lager:info("no agent ~s in account ~s", [AgentId, AcctId]);
        Pid -> acdc_agent_sup:status(Pid)
    end.

agent_login(AcctId, AgentId) ->
    put('callid', ?MODULE),
    Update = props:filter_undefined(
               [{<<"Account-ID">>, AcctId}
                ,{<<"Agent-ID">>, AgentId}
                |  wh_api:default_headers(?APP_NAME, ?APP_VERSION)
               ]),
    whapps_util:amqp_pool_send(Update, fun wapi_acdc_agent:publish_login/1),
    lager:info("published login update for agent").

agent_logout(AcctId, AgentId) ->
    put('callid', ?MODULE),
    Update = props:filter_undefined(
               [{<<"Account-ID">>, AcctId}
                ,{<<"Agent-ID">>, AgentId}
                |  wh_api:default_headers(?APP_NAME, ?APP_VERSION)
               ]),
    whapps_util:amqp_pool_send(Update, fun wapi_acdc_agent:publish_logout/1),
    lager:info("published logout update for agent").

agent_pause(AcctId, AgentId) ->
    agent_pause(AcctId, AgentId
                ,whapps_config:get(<<"acdc">>, <<"default_agent_pause_timeout">>, 600)
               ).
agent_pause(AcctId, AgentId, Timeout) ->
    put('callid', ?MODULE),
    Update = props:filter_undefined(
               [{<<"Account-ID">>, AcctId}
                ,{<<"Agent-ID">>, AgentId}
                ,{<<"Timeout">>, wh_util:to_integer(Timeout)}
                | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
               ]),
    whapps_util:amqp_pool_send(Update, fun wapi_acdc_agent:publish_pause/1),
    lager:info("published pause for agent").

agent_resume(AcctId, AgentId) ->
    put('callid', ?MODULE),
    Update = props:filter_undefined(
               [{<<"Account-ID">>, AcctId}
                ,{<<"Agent-ID">>, AgentId}
                |  wh_api:default_headers(?APP_NAME, ?APP_VERSION)
               ]),
    whapps_util:amqp_pool_send(Update, fun wapi_acdc_agent:publish_resume/1),
    lager:info("published resume for agent").


agent_queue_login(AcctId, AgentId, QueueId) ->
    put('callid', ?MODULE),
    Update = props:filter_undefined(
               [{<<"Account-ID">>, AcctId}
                ,{<<"Agent-ID">>, AgentId}
                ,{<<"Queue-ID">>, QueueId}
                |  wh_api:default_headers(?APP_NAME, ?APP_VERSION)
               ]),
    whapps_util:amqp_pool_send(Update, fun wapi_acdc_agent:publish_login_queue/1),
    lager:info("published login update for agent").

agent_queue_logout(AcctId, AgentId, QueueId) ->
    put('callid', ?MODULE),
    Update = props:filter_undefined(
               [{<<"Account-ID">>, AcctId}
                ,{<<"Agent-ID">>, AgentId}
                ,{<<"Queue-ID">>, QueueId}
                |  wh_api:default_headers(?APP_NAME, ?APP_VERSION)
               ]),
    whapps_util:amqp_pool_send(Update, fun wapi_acdc_agent:publish_logout_queue/1),
    lager:info("published logout update for agent").
