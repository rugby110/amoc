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
         create_node/5,
         make_jid/1,
         make_pubsub_node_id/1,
         publish_to_node/5,
         send_presence_available/1,
         send_presence_unavailable/1,
         subscribe_to_node/4]).


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
    <<"AmocNode", IdBin/binary>>.

create_node(MyJID, _Id, Client, PubSubAddr, NodeName) ->
    %% NodeName = make_pubsub_node_id(Id),
    CreateNodeStanza = escalus_pubsub_stanza:create_node_stanza(MyJID, <<"createid">>, PubSubAddr, NodeName),
    escalus_connection:send(Client, CreateNodeStanza),
    _CreateResp = escalus_connection:get_stanza(Client, create_resp, 5000),

    SubscribeStanza = escalus_pubsub_stanza:subscribe_by_user_stanza(MyJID, <<"subscrid">>, NodeName, PubSubAddr),

    lager:warning("will send subscribe request:~n~p~n", [SubscribeStanza]),
    escalus_connection:send(Client, SubscribeStanza),
    SubResp = escalus_connection:get_stanza(Client, sub_own_resp, 5000),
    lager:warning("subscr own resp ~p", [SubResp]).

make_item_id(Prefix, Id) ->
    IdBin = integer_to_binary(Id),
    <<Prefix/binary, IdBin/binary>>.

publish_to_node(MyJID, Id, Client, PubSubAddr, NodeName) ->
    PublishItemId = make_item_id(<<"Item">>, Id),
    lager:warning(" ---make item id : ~p", [PublishItemId]),

    PublishToNodeStanza = escalus_pubsub_stanza:publish_sample_content_stanza(NodeName,
                                                                              PubSubAddr,
                                                                              PublishItemId,
                                                                              MyJID,
                                                                              sample_one),
    lager:warning("---sending publish request ~p", [PublishToNodeStanza]),
    escalus_connection:send(Client, PublishToNodeStanza),
    PublishResponse = escalus_connection:get_stanza(Client, pub_own_resp, 5000),
    lager:warning("subscr own resp ~p", [PublishResponse]).




subscribe_to_node(MyJID, Client, Id, PubSubAddr) ->
    NodeName = make_pubsub_node_id(Id),
    SubscribeStanza = escalus_pubsub_stanza:subscribe_by_user_stanza(MyJID, <<"subscrid">>, NodeName, PubSubAddr),
    escalus_connection:send(Client, SubscribeStanza),
    SubResp = escalus_connection:get_stanza(Client, sub_resp, 5000),
    lager:warning("subscr resp ~p", [SubResp]).








