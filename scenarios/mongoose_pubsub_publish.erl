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
-module(mongoose_pubsub_publish).

-include_lib("exml/include/exml.hrl").
-include("pubsub_common.hrl").

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
    ok.

start(MyId) ->
    Res = <<"res1">>,
    Cfg = pubsub_utils:make_user(MyId, Res),

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

    MyJID = pubsub_utils:make_jid(MyId),
    lager:warning("my jid ~p", [MyJID]),
    do(IsChecker, <<MyJID/binary, "/" , Res/binary>>, MyId, Client),

    timer:sleep(?SLEEP_TIME_AFTER_SCENARIO),
    pubsub_utils:send_presence_unavailable(Client),
    escalus_connection:stop(Client).

do(_, MyJID, MyId, Client) ->

    escalus_connection:set_filter_predicate(Client, fun allow_only_pubsub_related/1),

    pubsub_utils:send_presence_available(Client),
    timer:sleep(1000),
    NodeName = pubsub_utils:make_pubsub_node_id(MyId),
    pubsub_utils:create_node(MyJID, MyId, Client, ?PUBSUB_ADDR, NodeName),
    timer:sleep(2000),
    NeighbourIds = lists:delete(MyId, lists:seq(max(1,MyId-?NUMBER_OF_PREV_NEIGHBOURS),
                                                 MyId+?NUMBER_OF_NEXT_NEIGHBOURS)),
    subscribe_to_neighbour_nodes(MyJID, Client, NeighbourIds),
    pubsub_utils:publish_to_node(MyJID, MyId, Client, ?PUBSUB_ADDR, NodeName).

%%     push_messages(MyJID, Client, NeighbourIds).



subscribe_to_neighbour_nodes(MyJid, Client, Ids) ->
    [pubsub_utils:subscribe_to_node(MyJid, Client, Id, ?PUBSUB_ADDR) || Id <- Ids].


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

allow_only_pubsub_related(Stanza) ->
     escalus_pred:is_stanza_from(?PUBSUB_ADDR, Stanza).



