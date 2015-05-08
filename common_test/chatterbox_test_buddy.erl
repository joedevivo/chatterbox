-module(chatterbox_test_buddy).

-compile([export_all]).

start(Config) ->
    application:load(chatterbox),
    Settings = [
    {port, 8081},
    {ssl, true},
    {ssl_options, [{certfile,   "../../../config/server.crt"},
                   {keyfile,    "../../../config/server.key"},
                   {cacertfile, "../../../config/server-ca.crt"},
                   {honor_cipher_order, false},
                   {versions, ['tlsv1.2']},
                   {next_protocols_advertised, [<<"h2">>]}]}
    ],
    [ok = application:set_env(chatterbox, Key, Value) || {Key, Value} <- Settings ],
    {ok, List} = application:ensure_all_started(chatterbox),
    ct:pal("Started: ~p", [List]),
    Config.

stop(_Config) ->
    application:stop(chatterbox),
    ok.