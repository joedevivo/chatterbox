-module(chatterbox_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    chatterbox_sup:start_link().

stop(_State) ->
    lager:info("Stopping Chatterbox"),
    ok.
