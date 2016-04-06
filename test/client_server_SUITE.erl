-module(client_server_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     {group, default_handler},
     {group, peer_handler}
    ].

groups() -> [{default_handler,  [complex_request,
                                 upgrade_tcp_connection,
                                 basic_push]},
             {peer_handler, [get_peer_in_handler]}
            ].

init_per_suite(Config) ->
    Config.

init_per_group(default_handler, Config) ->
    %% We'll start up a chatterbox server once, with this data_dir.
    NewConfig = [{www_root, data_dir},{initial_window_size,99999999}|Config],
    chatterbox_test_buddy:start(NewConfig);
init_per_group(_, Config) ->
    NewConfig = [{stream_callback_mod, peer_test_handler},
                 {initial_window_size,99999999}|Config],
    chatterbox_test_buddy:start(NewConfig),
    Config.

init_per_testcase(_, Config) ->
    Config.

end_per_group(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

end_per_suite(_Config) ->
    ok.

complex_request(_Config) ->
    application:set_env(chatterbox, client_initial_window_size, 99999999),
    {ok, Client} = http2_client:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, {ResponseHeaders, ResponseBody}} = http2_client:sync_request(Client, RequestHeaders, <<>>),

    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),

    ok.

upgrade_tcp_connection(_Config) ->
    {ok, Client} = http2_client:start_ssl_upgrade_link("localhost", 8081, <<>>, []),

    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, {ResponseHeaders, ResponseBody}} = http2_client:sync_request(Client, RequestHeaders, <<>>),
    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    ok.


basic_push(_Config) ->
    {ok, Client} = http2_client:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, {ResponseHeaders, ResponseBody}} = http2_client:sync_request(Client, RequestHeaders, <<>>),

    Streams = http2_connection:get_streams(Client),
    ct:pal("Streams ~p", [Streams]),

    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    13 = length(Streams),
    ok.

get_peer_in_handler(_Config) ->
    {ok, Client} = http2_client:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],


    {ok, {ResponseHeaders, ResponseBody}} = http2_client:sync_request(Client, RequestHeaders, <<>>),
    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    ok.
