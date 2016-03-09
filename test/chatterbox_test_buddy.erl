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

    application:set_env(chatterbox, stream_callback_mod,
                        proplists:get_value(stream_callback_mod, Config, chatterbox_static_stream)),

    application:set_env(chatterbox, server_header_table_size,
                        proplists:get_value(header_table_size, Config, 4096)),
    application:set_env(chatterbox, server_enable_push,
                        proplists:get_value(enable_push, Config, 1)),

    application:set_env(chatterbox, server_max_concurrent_streams,
                        proplists:get_value(max_concurrent_streams, Config, unlimited)),

    application:set_env(chatterbox, server_initial_window_size,
                        proplists:get_value(initial_window_size, Config, 65535)),

    application:set_env(chatterbox, server_max_frame_size,
                        proplists:get_value(max_frame_size, Config, 16384)),

    application:set_env(chatterbox, server_max_header_list_size,
                        proplists:get_value(max_header_list_size, Config, unlimited)),

    application:set_env(chatterbox, server_flow_control,
                        proplists:get_value(flow_control, Config, auto)),

    ct:pal("Settings ~p", [Settings]),
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
    ct:pal("chatterbox_test_buddy:stop/1"),
    application:stop(chatterbox),
    ranch:stop_listener(chatterbox_ranch_protocol),
    ok.
