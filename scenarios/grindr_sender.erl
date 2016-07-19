-module(grindr_sender).

-behaviour(amoc_scenario).

-export([init/0,
         start/1]).

-define(SENDER_USERS_CT, [amoc, counters, senders_users]).
-define(NUMBER_OF_PREV_NEIGHBOURS, amoc_config:get(no_of_prev_neighbours)).
-define(NUMBER_OF_NEXT_NEIGHBOURS, amoc_config:get(no_of_next_neighbours)).
-define(NUMBER_OF_SEND_MESSAGE_REPEATS, amoc_config:get(no_of_messages_repeats)).

init() ->
    ok = grindr_common:ensure_metrics(),
    exometer:new(?SENDER_USERS_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?SENDER_USERS_CT, [one, count], 10000),
    ok.

start(Id) ->
    Client = grindr_common:connect(Id),
    grindr_common:ignore_incoming(Client),
    grindr_common:send_initial_presence(Client),
    exometer:update(?SENDER_USERS_CT, 1),

    NeighbourIds = lists:delete(Id, lists:seq(max(1, Id - ?NUMBER_OF_PREV_NEIGHBOURS),
                                              Id + ?NUMBER_OF_NEXT_NEIGHBOURS)),
    send_messages_many_times(Client, sleep_time_after_message(), Id, NeighbourIds),

    timer:sleep(sleep_time_after_scenario()),
    grindr_common:disconnect(Client).

send_messages_many_times(Client, Interval, MyId, Ids) ->
    [ send_messages_to_neighbours(Client, MyId, Ids, Interval) ||
      _ <- lists:seq(1, ?NUMBER_OF_SEND_MESSAGE_REPEATS) ].

send_messages_to_neighbours(Client, MyId, Ids, SleepTime) ->
    [ grindr_common:send_message(Client, MyId, Id, SleepTime) || Id <- Ids ].

sleep_time_after_message() ->
    random:uniform(amoc_config:get(avg_sleep_time_after_message) * 2).

sleep_time_after_scenario() ->
    random:uniform(amoc_config:get(avg_sleep_time_after_scenario) * 2).
