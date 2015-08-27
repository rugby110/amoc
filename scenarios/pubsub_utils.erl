%%==============================================================================
%% Copyright 2015 Erlang Solutions Ltd.
%% Licensed under the Apache License, Version 2.0 (see LICENSE file)
%%==============================================================================
-module(pubsub_utils).

%%-define(HOST, <<"xmpp.esl.com">>). %% The virtual host served by the server
%%-define(SERVER_IPS, {<<"10.100.0.79">>, <<"10.100.0.80">>}). %% Tuple of servers, for example {<<"10.100.0.21">>, <<"10.100.0.22">>}

-include("pubsub_common.hrl").

-export([
         make_user/2,
         make_user_for_node/3,
         create_node/5,
         make_jid/1,
         make_pubsub_node_id/1,
         publish_to_node/5,
         request_all_items_and_check/5,
         send_presence_available/1,
         send_presence_unavailable/1,
         subscribe_to_node/5,
         delete_node/4]).


user_spec(ProfileId, Password, Res) ->
    [ {username, ProfileId},
      {server, ?HOST},
      {host, pick_server(?SERVER_IPS)},
      {password, Password},
      {carbons, false},
      {stream_management, false},
      {resource, Res}
    ].

user_spec_for_node(ProfileId, Password, Res, NodeIP) ->
    [ {username, ProfileId},
      {server, ?HOST},
      {host, NodeIP},
      {password, Password},
      {carbons, false},
      {stream_management, false},
      {resource, Res}
    ].


make_user_common(Id, R) ->
    BinId = integer_to_binary(Id),
    ProfileId = <<"user_", BinId/binary>>,
    Password = <<"password_", BinId/binary>>,
    {BinId, ProfileId, Password}.

make_user(Id, R) ->
    {BinId, ProfileId, Password} = make_user_common(Id, R),
    user_spec(ProfileId, Password, R).

make_user_for_node(Id, R, Node) ->
    {BinId, ProfileId, Password} = make_user_common(Id, R),
    user_spec_for_node(ProfileId, Password, R, Node).

pick_server(Servers) ->
    S = size(Servers),
    N = erlang:phash2(self(), S) + 1,
    element(N, Servers).

make_jid(Id) ->
    BinInt = integer_to_binary(Id),
    ProfileId = <<"user_", BinInt/binary>>,
    Host = ?HOST,
    << ProfileId/binary, "@", Host/binary >>.

send_presence_available(Client) ->
    Pres = escalus_stanza:presence(<<"available">>),
    escalus_connection:send(Client, Pres).

send_presence_unavailable(Client) ->
    Pres = escalus_stanza:presence(<<"unavailable">>),
    escalus_connection:send(Client, Pres).

%% ------- publish - subscribe specific functions ---------

make_pubsub_node_id(Id) ->
    IdBin = integer_to_binary(Id),
    <<"AmocTopic", IdBin/binary>>.

delete_node(_MyJID, Client, Id, PubSubAddr) ->
    NodeName = make_pubsub_node_id(Id),
    DeleteNode = escalus_pubsub_stanza:delete_node_stanza(NodeName),
    Id = <<"delete1">>,
    DeleteNodeIq  =  escalus_pubsub_stanza:iq_with_id(set, Id, PubSubAddr, Client,  [DeleteNode]),
    lager:debug(" REQUEST DeleteNodeIq: ~n~n~p~n",[DeleteNodeIq]),
    escalus_connection:send(Client, DeleteNodeIq).
    %%{true, _RecvdStanza} = wait_for_stanza_and_match_result_iq(User, Id, NodeAddr).


subscribe_to_node(MyJID, Client, Id, PubSubAddr, NodeName) ->
    %%NodeName = make_pubsub_node_id(Id),
    SubscribeStanza = escalus_pubsub_stanza:subscribe_by_user_stanza(MyJID, <<"subscrid">>, NodeName, PubSubAddr),
    escalus_connection:send(Client, SubscribeStanza),
    SubResp = escalus_connection:get_stanza(Client, sub_resp, 5000),
    lager:debug("~n SUBSCRIBE RESPONSE for process ~p ~p ~n", [self(),SubResp]).


create_node(MyJID, _Id, Client, PubSubAddr, NodeName) ->
    %% NodeName = make_pubsub_node_id(Id),
    CreateNodeStanza = escalus_pubsub_stanza:create_node_stanza(MyJID, <<"createid">>, PubSubAddr, NodeName),
    escalus_connection:send(Client, CreateNodeStanza),
    _CreateResp = escalus_connection:get_stanza(Client, create_resp, 5000).

    %%subscribe_to_node(MyJID, Client, <<"subscrid">>, PubSubAddr).

    %% SubscribeStanza = escalus_pubsub_stanza:subscribe_by_user_stanza(MyJID, <<"subscrid">>, NodeName, PubSubAddr),
    %% lager:warning("will send subscribe request:~n~p~n", [SubscribeStanza]),
    %% escalus_connection:send(Client, SubscribeStanza),
    %% SubResp = escalus_connection:get_stanza(Client, sub_own_resp, 5000),
    %% lager:warning("subscr own resp ~p", [SubResp]).

request_all_items_and_check(MyJID, Id, Client, PubSubAddr, NodeName) ->
    IqId = make_item_id(<<"getitems">>, Id),
    RequestAllItemsStanza = escalus_pubsub_stanza:create_request_allitems_stanza_with_iq(MyJID,
                                                                                         IqId,
                                                                                         PubSubAddr,
                                                                                         NodeName),
    %%lager:warning(" REQUESTING items : ~p", [RequestAllItemsStanza]),
    escalus:send(Client, RequestAllItemsStanza),
    {true, _Res1} = wait_for_stanza_and_match_result_iq(MyJID, IqId, NodeName).
    %%lager:warning(" Requested items for Client: ~n~n~p~n",[exml:to_binary(Res1)]).

%% todo : move this method from pubsub_tools somewhere to escalus!!!!
wait_for_stanza_and_match_result_iq(User, Id, DestinationNode) ->
    ResultStanza = escalus:wait_for_stanza(User),
    QueryStanza = escalus_stanza:iq_with_type_id_from(<<"result">>, Id, DestinationNode),
    Result = escalus_pred:is_iq_result(QueryStanza, ResultStanza),
    {Result, ResultStanza}.


make_item_id(Prefix, Id) ->
    IdBin = integer_to_binary(Id),
    <<Prefix/binary, IdBin/binary>>.

publish_to_node(MyJID, Id, Client, PubSubAddr, NodeName) ->

    PublishItemId = <<"publishedItemId">>,

    PublishToNodeStanza = escalus_pubsub_stanza:publish_sample_content_stanza(NodeName,
                                                                              PubSubAddr,
                                                                              PublishItemId,
                                                                              MyJID,
                                                                              sample_time),
    lager:debug("~n publish request ~p at ~p ~n", [PublishToNodeStanza, node()]),
    escalus_connection:send(Client, PublishToNodeStanza),
    PublishResponse = escalus_connection:get_stanza(Client, pub_own_resp, 5000),
    lager:debug("~n publish resp for proc ~p, client ~p: ~p~n", [self(),Id, PublishResponse]).









