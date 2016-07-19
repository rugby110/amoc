-module(grindr_common).

-include_lib("exml/include/exml.hrl").

-define(HOST, amoc_config:get(xmpp_host)). %% The virtual host served by the server
-define(SERVER_IPS, amoc_config:get(xmpp_servers)). %% Tuple of servers, for example {<<"10.100.0.21">>, <<"10.100.0.22">>}

%% message length distribution
-define(ALFA, 1.32653237).
-define(BETA, 0.08970633).

-export([ensure_metrics/0,
         connect/1,
         send_initial_presence/1,
         ignore_incoming/1,
         disconnect/1, 
         send_message/4,
         send_message/5]).

-define(MESSAGES_CT, [amoc, counters, messages_sent]).
-define(MESSAGE_LENGTH_CT, [amoc, counters, message_length]).

%% Public functions
ensure_metrics() ->
    catch exometer:new(?MESSAGES_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGES_CT, [one, count], 10000),
    catch exometer:new(?MESSAGE_LENGTH_CT, histogram),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGE_LENGTH_CT, [mean, min, max, median, 95, 99, 999], 10000),
    ok.

connect(Id) ->
    random:seed(os:timestamp()),
    Cfg = make_user(Id, <<"res1">>),
    {ConnectionTime, ConnectionResult} = timer:tc(escalus_connection, start, [Cfg]),
    case ConnectionResult of
        {ok, ConnectedClient, _, _} ->
            exometer:update([amoc, counters, connections], 1),
            exometer:update([amoc, times, connection], ConnectionTime),
            ConnectedClient;
        Error ->
            exometer:update([amoc, counters, connection_failures], 1),
            lager:error("Could not connect user=~p, reason=~p", [Cfg, Error]),
            exit(connection_failed)
    end.

disconnect(Client) ->
    send_presence_unavailable(Client),
    escalus_connection:stop(Client).

send_message(Client, MyId, ToId, SleepTime) ->
    DistLength = erlang:round(random2:gamma(?ALFA, ?BETA)),
    send_message(Client, MyId, ToId, SleepTime, DistLength).

send_message(Client, MyId, ToId, SleepTime, Length) ->
    MsgIn = make_message(MyId, ToId, Length),
    escalus_connection:send(Client, MsgIn),
    exometer:update(?MESSAGES_CT, 1),
    timer:sleep(SleepTime).

send_initial_presence(Client) ->
    Pres = escalus_stanza:presence(<<"available">>),
    escalus_connection:send(Client, Pres).

ignore_incoming(Client) ->
    escalus_connection:set_filter_predicate(Client, none).

%% Internal functions
user_spec(ProfileId, Password, Res) ->
    [ {username, ProfileId},
      {server, ?HOST},
      {host, pick_server(?SERVER_IPS)},
      {password, Password},
      {starttls, amoc_config:get(starttls)},
      {carbons, amoc_config:get(carbons)},
      {stream_management, amoc_config:get(stream_management)},
      {resource, Res}
    ].

profile_id(Id) ->
    BinId = integer_to_binary(Id),
    <<"user_", BinId/binary>>.

make_user(Id, R) ->
    BinId = integer_to_binary(Id),
    ProfileId = profile_id(Id),
    Password = <<"password_", BinId/binary>>,
    user_spec(ProfileId, Password, R).

send_presence_unavailable(Client) ->
    Pres = escalus_stanza:presence(<<"unavailable">>),
    escalus_connection:send(Client, Pres).

make_message(SourceId, TargetId, MsgLength) ->
    exometer:update(?MESSAGE_LENGTH_CT, MsgLength),
    Body = random_message(SourceId, TargetId, MsgLength),
    Id = escalus_stanza:id(),
    escalus_stanza:set_id(escalus_stanza:chat_to(make_jid(TargetId), Body), Id).

make_jid(Id) ->
    BinInt = integer_to_binary(Id),
    ProfileId = <<"user_", BinInt/binary>>,
    Host = ?HOST,
    << ProfileId/binary, "@", Host/binary >>.

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

pick_server(Servers) ->
    S = size(Servers),
    N = erlang:phash2(self(), S) + 1,
    element(N, Servers).
