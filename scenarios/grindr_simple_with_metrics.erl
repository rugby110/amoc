%%==============================================================================
%% Copyright 2015 Erlang Solutions Ltd.
%% Licensed under the Apache License, Version 2.0 (see LICENSE file)
%%
%% In this scenarion users are sending message to its neighbours
%% (users wiht lower and grater idea defined by NUMBER_OF_*_NEIGHBOURS values)
%% Messages will be send NUMBER_OF_SEND_MESSAGE_REPEATS to every selected neighbour
%% after every message given the script will wait SLEEP_TIME_AFTER_EVERY_MESSAGE ms
%% Every CHECKER_SESSIONS_INDICATOR is a checker session which just measures message TTD
%%
%%==============================================================================
-module(grindr_simple_with_metrics).

-include_lib("exml/include/exml.hrl").

-define(HOST, amoc_config:get(xmpp_host)). %% The virtual host served by the server
-define(SERVER_IPS, amoc_config:get(xmpp_servers)). %% Tuple of servers, for example {<<"10.100.0.21">>, <<"10.100.0.22">>}
-define(CHECKER_SESSIONS_INDICATOR, amoc_config:get(checker_session)). %% How often a checker session should be generated
-define(NUMBER_OF_PREV_NEIGHBOURS, amoc_config:get(no_of_prev_neighbours)).
-define(NUMBER_OF_NEXT_NEIGHBOURS, amoc_config:get(no_of_next_neighbours)).
-define(NUMBER_OF_SEND_MESSAGE_REPEATS, amoc_config:get(no_of_messages_repeats)).

%% message length distribution
-define(ALFA, 1.32653237).
-define(BETA, 0.08970633).

-behaviour(amoc_scenario).

-export([start/1]).
-export([init/0]).

-define(MESSAGES_CT, [amoc, counters, messages_sent]).
-define(MESSAGE_TTD_CT, [amoc, times, message_ttd]).
-define(MESSAGE_LENGTH_CT, [amoc, counters, message_length]).
-define(REGULAR_USER_CT, [amoc, counters, regular_users]).
-define(CHECKER_USER_CT, [amoc, counters, checker_users]).
-define(SPAMMER_USER_CT, [amoc, counters, spammer_users]).

-type binjid() :: binary().

-spec init() -> ok.
init() ->
    lager:info("init some metrics"),
    exometer:new(?MESSAGES_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGES_CT, [one, count], 10000),
    exometer:new(?MESSAGE_TTD_CT, histogram),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGE_TTD_CT, [mean, min, max, median, 95, 99, 999], 10000),
    exometer:new(?MESSAGE_LENGTH_CT, histogram),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGE_LENGTH_CT, [mean, min, max, median, 95, 99, 999], 10000),
    ok.

-spec user_spec(binary(), binary(), binary()) -> escalus_users:user_spec().
user_spec(ProfileId, Password, Res) ->
    [ {username, ProfileId},
      {server, ?HOST},
      {host, pick_server(?SERVER_IPS)},
      {password, Password},
      {carbons, false},
      {stream_management, false},
      {resource, Res},
      {tcp_opts, [{reuseaddr, true}]}
    ].

profile_id(Id) ->
    BinId = integer_to_binary(Id),
    <<"user_", BinId/binary>>.

-spec make_user(amoc_scenario:user_id(), binary()) -> escalus_users:user_spec().
make_user(Id, R) ->
    BinId = integer_to_binary(Id),
    ProfileId = profile_id(Id),
    Password = <<"password_", BinId/binary>>,
    user_spec(ProfileId, Password, R).

-spec start(amoc_scenario:user_id()) -> any().
start(MyId) ->
    random:seed(os:timestamp()),
    Cfg = make_user(MyId, <<"res1">>),

    IsChecker = MyId rem ?CHECKER_SESSIONS_INDICATOR == 0,

    {ConnectionTime, ConnectionResult} = timer:tc(escalus_connection, start, [Cfg]),
    Client = case ConnectionResult of
        {ok, ConnectedClient, _, _} ->
            exometer:update([amoc, counters, connections], 1),
            exometer:update([amoc, times, connection], ConnectionTime),
            ConnectedClient;
        Error ->
            exometer:update([amoc, counters, connection_failures], 1),
            lager:error("Could not connect user=~p, reason=~p", [Cfg, Error]),
            exit(connection_failed)
    end,

    do(IsChecker, MyId, Client),

    timer:sleep(sleep_time_after_scenario()),
    send_presence_unavailable(Client),
    escalus_connection:stop(Client).

-spec do(boolean(), amoc_scenario:user_id(), escalus:client()) -> any().
do(false, MyId, Client) ->
    escalus_connection:set_filter_predicate(Client, none),
    send_presence_available(Client),
    NeighbourIds = lists:delete(MyId, lists:seq(max(1,MyId-?NUMBER_OF_PREV_NEIGHBOURS),
                                                MyId+?NUMBER_OF_NEXT_NEIGHBOURS)),
    send_messages_many_times(Client, sleep_time_after_message(), MyId, NeighbourIds);
do(_Other, _MyId, Client) ->
    lager:info("checker"),
    send_presence_available(Client),
    receive_forever(Client).

-spec receive_forever(escalus:client()) -> no_return().
receive_forever(Client) ->
    Stanza = escalus_connection:get_stanza(Client, message, infinity),
    Now = usec:from_now(os:timestamp()),
    case exml_query:path(Stanza, [{element, <<"body">>}, cdata]) of
	undefined ->
		ok;
	Body ->
            {struct, Json} = mochijson2:decode(Body),
            case lists:keyfind(<<"timestamp">>, 1, Json) of
                {_, Sent} ->
                    TTD = (Now - binary_to_integer(Sent)),
                    exometer:update(?MESSAGE_TTD_CT, TTD);
                _ ->
                    ok
            end
    end,
    receive_forever(Client).

-spec send_presence_available(escalus:client()) -> ok.
send_presence_available(Client) ->
    Pres = escalus_stanza:presence(<<"available">>),
    escalus_connection:send(Client, Pres).

-spec send_presence_unavailable(escalus:client()) -> ok.
send_presence_unavailable(Client) ->
    Pres = escalus_stanza:presence(<<"unavailable">>),
    escalus_connection:send(Client, Pres).

send_messages_many_times(Client, MessageInterval, MyId, NeighbourIds) ->
    S = fun(_) ->
                send_messages_to_neighbors(Client, MyId, NeighbourIds, MessageInterval)
        end,
    lists:foreach(S, lists:seq(1, ?NUMBER_OF_SEND_MESSAGE_REPEATS)).


send_messages_to_neighbors(Client, MyId, TargetIds, SleepTime) ->
    [send_message(Client, MyId, TargetId, SleepTime)
     || TargetId <- TargetIds].

send_message(Client, MyId, ToId, SleepTime) ->
    MsgIn = make_message(MyId, ToId),
    escalus_connection:send(Client, MsgIn),
    exometer:update([amoc, counters, messages_sent], 1),
    timer:sleep(SleepTime).

make_message(SourceId, TargetId) ->
    MsgLength = erlang:round(random2:gamma(?ALFA, ?BETA)),
    exometer:update(?MESSAGE_LENGTH_CT, MsgLength),
    Body = random_message(SourceId, TargetId, MsgLength),
    Id = escalus_stanza:id(),
    escalus_stanza:set_id(escalus_stanza:chat_to(make_jid(TargetId), Body), Id).

-spec make_jid(amoc_scenario:user_id()) -> binjid().
make_jid(Id) ->
    BinInt = integer_to_binary(Id),
    ProfileId = <<"user_", BinInt/binary>>,
    Host = ?HOST,
    << ProfileId/binary, "@", Host/binary >>.

-spec pick_server({binary()}) -> binary().
pick_server(Servers) ->
    S = size(Servers),
    N = erlang:phash2(self(), S) + 1,
    element(N, Servers).

random_message(SourceId, TargetId, Len) ->
    Struct = {struct, [{targetProfileId, profile_id(TargetId)},
                       {sourceProfileId, profile_id(SourceId)},
                       {type, <<"text">>},
                       {timestamp, integer_to_binary(usec:from_now(os:timestamp()))},
                       {sourceDisplayName, <<"abc">>},
                       {messageId, <<"26022E06-EE5D-4090-AA2F-145635CB1388">>},
                       {body, random_text(Len)}]},
    mochijson2:encode(Struct).

random_text(Len) ->
    list_to_binary([ random:uniform($z-$a) + $a - 1 || _ <- lists:seq(1, Len) ]).

sleep_time_after_scenario() ->
    random:uniform(amoc_config:get(avg_sleep_time_after_scenario) * 2).

sleep_time_after_message() ->
    random:uniform(amoc_config:get(avg_sleep_time_after_message) * 2).
