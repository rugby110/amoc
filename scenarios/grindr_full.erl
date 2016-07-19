-module(grindr_full).

-behaviour(amoc_scenario).

-export([start/1]).
-export([init/0]).

init() ->
    ok = grindr_common:ensure_metrics(),
    [ ok = M:init() || M <- scenarios() ],
    ok.

start(Id) ->
    Scenario = scenario(Id),
    Scenario:start(Id),
    ok.

scenarios() ->
    [grindr_watcher, grindr_spammer, grindr_sender].

scenario(Id) ->
    case Id rem amoc_config:get(watcher_session) of
        0 ->
            grindr_watcher;
        _ ->
            case Id rem amoc_config:get(spammer_session) of
                0 -> grindr_spammer;
                _ -> grindr_sender
            end
    end.
