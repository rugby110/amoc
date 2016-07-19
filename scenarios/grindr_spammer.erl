-module(grindr_spammer).

-behaviour(amoc_scenario).

-export([init/0,
         start/1]).

-define(NEIGHBOURS, amoc_config:get(spammer_neighbours)).
-define(MESSAGE_LENGTH, amoc_config:get(spammer_msg_length)).
-define(WAIT_TILL_NEXT_ATTACK, amoc_config:get(spammer_interarrival)).

-define(SPAMMER_USERS_CT, [amoc, counters, spammer_users]).

init() ->
    ok = grindr_common:ensure_metrics(),
    exometer:new(?SPAMMER_USERS_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?SPAMMER_USERS_CT, [one, count], 10000),
    ok.

start(Id) ->
    Client = grindr_common:connect(Id),
    grindr_common:ignore_incoming(Client),
    grindr_common:send_initial_presence(Client),

    exometer:update(?SPAMMER_USERS_CT, 1),

    send_spam_messages(Id, Client), 
    timer:sleep(?WAIT_TILL_NEXT_ATTACK),
    grindr_common:disconnect(Client),
    ok.

send_spam_messages(MyId, Client) ->
    Ids = lists:seq(MyId+1, MyId+?NEIGHBOURS),
    [ grindr_common:send_message(Client, MyId, Id, amoc_config:get(spammer_sleep), ?MESSAGE_LENGTH)
      || Id <- Ids ].
