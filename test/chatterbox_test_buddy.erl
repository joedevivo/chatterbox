-module(chatterbox_test_buddy).

-compile([export_all]).

-include_lib("common_test/include/ct.hrl").

start(Config) ->
    application:load(chatterbox),
    Config2 = ensure_ssl(Config),
    PreDataSettings = [
    {port, 8081},
    {ssl, ?config(ssl, Config2)},
    {ssl_options, [{certfile,   "../../../../config/localhost.crt"},
                   {keyfile,    "../../../../config/localhost.key"},
                   {honor_cipher_order, false},
                   {versions, ['tlsv1.2']},
                   {next_protocols_advertised, [<<"h2">>]}]}
    ],

    Settings =
        case ?config(www_root, Config) of
            undefined ->
                [{chatterbox_static_content_handler,
                  [{root_dir, code:priv_dir(chatterbox)}]}|PreDataSettings];
            data_dir ->
                Root = ?config(data_dir, Config),
                [{chatterbox_static_content_handler,
                  [{root_dir, Root}]}|PreDataSettings];
            WWWRoot ->
                [{chatterbox_static_content_handler,
                  [{root_dir, WWWRoot}]}|PreDataSettings]
        end,

    cthr:pal("Settings ~p", [Settings]),
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
    cthr:pal("chatterbox_test_buddy:stop/1"),
    application:stop(chatterbox),
    ok.
