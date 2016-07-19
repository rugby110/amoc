-module(grindr_watcher).

-behaviour(amoc_scenario).

-export([init/0,
         start/1]).

-define(WATCHER_USERS_CT, [amoc, counters, watcher_users]).
-define(MESSAGE_TTD_CT, [amoc, times, message_ttd]).

init() ->
    ok = grindr_common:ensure_metrics(),
    exometer:new(?WATCHER_USERS_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?WATCHER_USERS_CT, [one, count], 10000),
    exometer:new(?MESSAGE_TTD_CT, histogram),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGE_TTD_CT, [mean, min, max, median, 95, 99, 999], 10000),
    ok.

start(Id) ->
    Client = grindr_common:connect(Id),
    grindr_common:send_initial_presence(Client),
    exometer:update(?WATCHER_USERS_CT, 1),
    receive_forever(Client).

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
