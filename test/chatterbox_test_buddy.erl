-module(chatterbox_test_buddy).

-compile([export_all]).

-include_lib("common_test/include/ct.hrl").

start(Config) ->
    application:load(chatterbox),
    Config2 = ensure_ssl(Config),
    Settings = [
    {port, 8081},
    {ssl, ?config(ssl, Config2)},
    {ssl_options, [{certfile,   "../../../../config/localhost.crt"},
                   {keyfile,    "../../../../config/localhost.key"},
                   {honor_cipher_order, false},
                   {versions, ['tlsv1.2']},
                   {next_protocols_advertised, [<<"h2">>]}]}
    ],
    ct:pal("Settings ~p", [Settings]),
    [ok = application:set_env(chatterbox, Key, Value) || {Key, Value} <- Settings ],
    {ok, List} = application:ensure_all_started(chatterbox),
    ct:pal("Started: ~p", [List]),
    Config.

ssl(SSLBool, Config) ->
    [{ssl, SSLBool}|Config].

ensure_ssl(Config) ->
    case ?config(ssl, Config) of
        undefined ->
            ssl(true, Config);
        _SSL ->
            Config
    end.

stop(_Config) ->
    ct:pal("chatterbox_test_buddy:stop/1"),
    application:stop(chatterbox),
    ok.
