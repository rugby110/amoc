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
-module(mongoose_pubsub_Xs_nodes).

-include_lib("exml/include/exml.hrl").
-include("pubsub_common.hrl").

-define(NODE_SUBSCRIBERS, 500).
-define(CHECKER_SESSIONS_INDICATOR, ?NODE_SUBSCRIBERS div 2). %% How often a checker session should be generated
-define(SLEEP_TIME_AFTER_SCENARIO, 90000). %% wait 10s after scenario before disconnecting
%% -define(NUMBER_OF_PREV_NEIGHBOURS, 5). %2
%% -define(NUMBER_OF_NEXT_NEIGHBOURS, 0). %2
-define(NUMBER_OF_SEND_MESSAGE_REPEATS, 10).
-define(SLEEP_TIME_AFTER_EVERY_MESSAGE, 200).

-define(PUBSUB_ADDR, <<"pubsub.", (?HOST)/binary>>).

-export([start/1]).
-export([init/0]).

-define(MESSAGE_PUBSUB_TTD_CT, [amoc, times, message_pubsub_ttd]).
-define(PUBSUB_TT_CREATE_CT, [amoc, times, message_pubsub_ttc]).
-define(PUBSUB_TT_SUBSCRIBE_CT, [amoc, times, message_pubsub_tts]).
-define(PUBSUB_TT_RECEIVE_CT, [amoc, times, message_pubsub_ttr]).

init() ->
    [begin
         exometer:new(Name, histogram),
         exometer_report:subscribe(exometer_report_graphite, Name, [mean, min, max, median, 95, 99, 999], 10000)
     end || Name <- [
                     ?MESSAGE_PUBSUB_TTD_CT,
                     ?PUBSUB_TT_CREATE_CT,
                     ?PUBSUB_TT_SUBSCRIBE_CT,
                     ?PUBSUB_TT_RECEIVE_CT]].

start(MyId) ->

    MyIdBin = integer_to_binary(MyId),
    Res = <<"res1">>,
    Cfg = user_spec(<<"user_",MyIdBin/binary>>, <<"password_",MyIdBin/binary>>, Res),

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
%%     lager:warning("~n-------- my JID: ~p, MyId: ~p, my PID: ~p~n", [MyJID, MyId, self()]),

    escalus_connection:set_filter_predicate(Client, fun allow_only_pubsub_related/1),

    pubsub_utils:send_presence_available(Client),

    NodeID = ?NODE_SUBSCRIBERS * (MyId div ?NODE_SUBSCRIBERS) + 1,
    MyBareJID = pubsub_utils:make_jid(MyId),
    MyJID = <<MyBareJID/binary, "/" , Res/binary>>,
    maybe_create_node_and_subscribe(MyId, NodeID, MyJID, Client),
    timer:sleep(1000),

    do(IsChecker, MyJID, MyId, NodeID, Client),

    timer:sleep(timer:minutes(10)),
    flush_msgs(),
    pubsub_utils:send_presence_unavailable(Client),
    escalus_connection:stop(Client).

%%only if node id matches session id
maybe_create_node_and_subscribe(MyId, MyId, MyJID, Client) ->
    NodeName = pubsub_utils:make_pubsub_node_id(MyId),
    do_create_node(NodeName, MyJID, Client),
    do_subscribe_node(NodeName, MyJID, Client);
%% others subscribe
maybe_create_node_and_subscribe(MyId, NodeId, MyJID, Client) ->
    NodeName = pubsub_utils:make_pubsub_node_id(NodeId),
    do_subscribe_node(NodeName, MyJID, Client).

do(true, _MyJID, _MyId, _, Client) ->
    receive_forever(Client);
do(_, MyJID, MyId, NodeId, Client) ->
    NodeName = pubsub_utils:make_pubsub_node_id(NodeId),
    [publish_to_node(MyJID, MyId, Client, NodeName) || _ <- lists:seq(1, 5)].

do_create_node(NodeName, MyJID, Client) ->
    TimeBeforeCreateNode = os:timestamp(),
    pubsub_utils:create_node(MyJID, MyJID, Client, ?PUBSUB_ADDR, NodeName),
    exometer:update(?PUBSUB_TT_CREATE_CT, timer:now_diff(os:timestamp(), TimeBeforeCreateNode)).

do_subscribe_node(NodeName, MyJID, Client) ->
    TimeBeforeSubscribe = os:timestamp(),
    pubsub_utils:subscribe_to_node(MyJID, Client, NodeName, ?PUBSUB_ADDR, NodeName),
    exometer:update(?PUBSUB_TT_SUBSCRIBE_CT, timer:now_diff(os:timestamp(), TimeBeforeSubscribe)).

flush_msgs() ->
    receive
        _ ->
            flush_msgs()
    after 0 ->
        ok
    end.

publish_to_node(MyJid, MyId, Client, NodeName) ->
    timer:sleep(?SLEEP_TIME_AFTER_EVERY_MESSAGE),
    pubsub_utils:publish_to_node(MyJid, MyId, Client, ?PUBSUB_ADDR, NodeName).


receive_forever(Client) ->
    case escalus_connection:get_stanza(Client, message, infinity) of
        Msg = #xmlel{name = <<"message">>} ->
            lager:warning("<><><><><><>from ~p <><> ~p~n ",[node(), Msg]),
            Now = usec:from_now(os:timestamp()),
            case get_timestamp_from_message(Msg) of
                {ok, SentAt} ->
                    Delay = Now - binary_to_integer(SentAt),
                    lager:warning("@@@DELAY (ms) @@@@@,~p~n", [Delay/100]),
                    exometer:update(?PUBSUB_TT_RECEIVE_CT, Delay);
                _ ->
                    lager:warning("###### publisher retracted items ######")
            end;
            _ -> ok
                                           end,
    receive_forever(Client).

%% ...extracting previously published timestamp
get_timestamp_from_message(EventMessage = #xmlel{name = <<"message">>}) ->
    Event = exml_query:subelement(EventMessage, <<"event">>),
    ItemsWrapper = exml_query:subelement(Event, <<"items">>),
    Items = exml_query:subelements(ItemsWrapper, <<"item">>),

    case Items of
        [] -> {error, 666};
        _  ->
            Item = hd(Items),
            Entry = exml_query:subelement(Item, <<"entry">>),
            TimeStampEl = exml_query:subelement(Entry, <<"MSG_SENT_AT">>),
            TimeStamp = exml_query:cdata(TimeStampEl),
            {ok, TimeStamp}
    end.

allow_only_pubsub_related(Stanza) ->
     escalus_pred:is_stanza_from(?PUBSUB_ADDR, Stanza).


user_spec(ProfileId, Password, Res) ->
    [ {username, ProfileId},
      {server, ?HOST},
      {host, pick_server(?SERVER_IPS)},
      {password, Password},
      {carbons, false},
      {stream_management, false},
      {resource, Res}
    ].

pick_server(Servers) ->
    S = size(Servers),
    N = erlang:phash2(self(), S) + 1,
    element(N, Servers).