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
-module(mongoose_pubsub).

-include_lib("exml/include/exml.hrl").

-define(HOST, <<"xmpp.esl.com">>). %% The virtual host served by the server
-define(SERVER_IPS, {<<"10.100.0.79">>, <<"10.100.0.80">>}). %% Tuple of servers, for example {<<"10.100.0.21">>, <<"10.100.0.22">>}
-define(CHECKER_SESSIONS_INDICATOR, 10). %% How often a checker session should be generated
-define(SLEEP_TIME_AFTER_SCENARIO, 10000). %% wait 10s after scenario before disconnecting
-define(NUMBER_OF_PREV_NEIGHBOURS, 2).
-define(NUMBER_OF_NEXT_NEIGHBOURS, 1).
-define(NUMBER_OF_SEND_MESSAGE_REPEATS, 73).
-define(SLEEP_TIME_AFTER_EVERY_MESSAGE, 20000).

-define(PUBSUB_ADDR, <<"pubsub.", (?HOST)/binary>>).

-export([start/1]).
-export([init/0]).

-define(MESSAGES_CT, [amoc, counters, messages_sent]).
-define(MESSAGE_TTD_CT, [amoc, times, message_ttd]).

init() ->
    lager:info("init some metrics"),
%%     exometer:new(?MESSAGES_CT, spiral),
%%     exometer_report:subscribe(exometer_report_graphite, ?MESSAGES_CT, [one, count], 10000),
%%     exometer:new(?MESSAGE_TTD_CT, histogram),
%%     exometer_report:subscribe(exometer_report_graphite, ?MESSAGE_TTD_CT, [mean, min, max, median, 95, 99, 999], 10000),
    ok.

user_spec(ProfileId, Password, Res) ->
    [ {username, ProfileId},
      {server, ?HOST},
      {host, pick_server(?SERVER_IPS)},
      {password, Password},
      {carbons, false},
      {stream_management, false},
      {resource, Res}
    ].

make_user(Id, R) ->
    BinId = integer_to_binary(Id),
    ProfileId = <<"user_", BinId/binary>>,
    Password = <<"password_", BinId/binary>>,
    user_spec(ProfileId, Password, R).

start(MyId) ->
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

    timer:sleep(?SLEEP_TIME_AFTER_SCENARIO),
    send_presence_unavailable(Client),
    escalus_connection:stop(Client).

do(_, MyId, Client) ->

    escalus_connection:set_filter_predicate(Client, fun allow_only_pubsub_related/1),

    send_presence_available(Client),
    timer:sleep(1000),
    create_node(Client, MyId),
    timer:sleep(2000),
    NeighbourIds = lists:delete(MyId, lists:seq(max(1,MyId-?NUMBER_OF_PREV_NEIGHBOURS),
                                                MyId+?NUMBER_OF_NEXT_NEIGHBOURS)),
    subscribe_to_neighbour_nodes(Client, NeighbourIds),
    push_messages(Client, NeighbourIds).

allow_only_pubsub_related(Stanza) ->
    escalus_pred:is_stanza_from(?PUBSUB_ADDR, Stanza).

create_node(Client, Id) ->
    NodeName = make_pubsub_node(Id),
    MyJID = make_jid(Id),
    CreateNodeStanza = escalus_pubsub_stanza:create_node_stanza(MyJID, ?PUBSUB_ADDR, NodeName),
    escalus_connection:send(Client, CreateNodeStanza),
    _CreateResp = escalus_connection:get_stanza(Client, create_resp, 5000),
    SubscribeStanza = escalus_pubsub_stanza:subscribe_by_user_stanza(MyJID, NodeName, ?PUBSUB_ADDR),
    escalus_connection:send(Client, SubscribeStanza),
    SubResp = escalus_connection:get_stanza(Client, subscri_resp, 5000),
    lager:warning("create stanza ~p, resp ~p", [SubscribeStanza, SubResp]).

subscribe_to_neighbour_nodes(Client, Ids) ->
    [subscribe_to_node(Client, Id) || Id <- Ids].

subscribe_to_node(Client, Id) ->
    NodeName = make_pubsub_node(Id).

push_messages(Client, Ids) ->
    [push_message(Client, Id) || Id <- Ids].

push_message(Client, Id) ->
    NodeName = make_pubsub_node(Id).

make_pubsub_node(Id) ->
    IdBin = integer_to_binary(Id),
    <<"AmocNode", IdBin/binary>>.

receive_forever(Client) ->
    Stanza = escalus_connection:get_stanza(Client, message, infinity),
    Now = usec:from_now(os:timestamp()),
    case Stanza of
        #xmlel{name = <<"message">>, attrs=Attrs} ->
            case lists:keyfind(<<"timestamp">>, 1, Attrs) of
                {_, Sent} ->
                    TTD = (Now - binary_to_integer(Sent)),
                    exometer:update(?MESSAGE_TTD_CT, TTD);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    receive_forever(Client).


send_presence_available(Client) ->
    Pres = escalus_stanza:presence(<<"available">>),
    escalus_connection:send(Client, Pres).

send_presence_unavailable(Client) ->
    Pres = escalus_stanza:presence(<<"unavailable">>),
    escalus_connection:send(Client, Pres).

make_jid(Id) ->
    BinInt = integer_to_binary(Id),
    ProfileId = <<"user_", BinInt/binary>>,
    Host = ?HOST,
    << ProfileId/binary, "@", Host/binary >>.

pick_server(Servers) ->
    S = size(Servers),
    N = erlang:phash2(self(), S) + 1,
    element(N, Servers).
