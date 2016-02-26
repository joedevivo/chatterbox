-module(chatterbox_test_buddy).

-compile([export_all]).

-include_lib("common_test/include/ct.hrl").

start(Config) ->
    application:load(chatterbox),
    ok = application:ensure_started(ranch),
    Config2 = ensure_ssl(Config),
    PreDataSettings = [
    {port, 8081},
    {ssl, ?config(ssl, Config2)},
    {ssl_options, [{certfile,   "../../../../config/localhost.crt"},
                   {keyfile,    "../../../../config/localhost.key"},
                   {honor_cipher_order, false},
                   {versions, ['tlsv1.2']},
                   {alpn_preferred_protocols, [<<"h2">>]}]}
    ],

    Settings =
        case ?config(www_root, Config) of
            undefined ->
                [{chatterbox_static_stream,
                  [{root_dir, code:priv_dir(chatterbox)}]}|PreDataSettings];
            data_dir ->
                Root = ?config(data_dir, Config),
                [{chatterbox_static_stream,
                  [{root_dir, Root}]}|PreDataSettings];
            WWWRoot ->
                [{chatterbox_static_stream,
                  [{root_dir, WWWRoot}]}|PreDataSettings]
        end,

    cthr:pal("Settings ~p", [Settings]),
    [ok = application:set_env(chatterbox, Key, Value) || {Key, Value} <- Settings ],
    {ok, List} = application:ensure_all_started(chatterbox),
    ct:pal("Started: ~p", [List]),

    {ok, _RanchPid} =
        ranch:start_listener(
          chatterbox_ranch_protocol,
          10,
          ranch_ssl,
          [{port, 8081}|proplists:get_value(ssl_options, Settings)],
          chatterbox_ranch_protocol,
          []),
    lager:set_loglevel(cth_readable_lager_backend, debug),

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
    cthr:pal("chatterbox_test_buddy:stop/1"),
    application:stop(chatterbox),
    ranch:stop_listener(chatterbox_ranch_protocol),
    ok.
