-module(client_server_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     {group, default_handler},
     {group, peer_handler},
     {group, double_body_handler},
     {group, echo_handler}
    ].

groups() -> [{default_handler,  [complex_request,
                                 upgrade_tcp_connection,
                                 basic_push]},
             {peer_handler, [get_peer_in_handler]},
             {double_body_handler, [send_body_opts]},
             {echo_handler, [echo_body]}
            ].

init_per_suite(Config) ->
    Config.

init_per_group(default_handler, Config) ->
    %% We'll start up a chatterbox server once, with this data_dir.
    NewConfig = [{www_root, data_dir},{initial_window_size,99999999}|Config],
    chatterbox_test_buddy:start(NewConfig);
init_per_group(double_body_handler, Config) ->
    NewConfig = [{stream_callback_mod, double_body_handler},
                 {initial_window_size,99999999}|Config],
    chatterbox_test_buddy:start(NewConfig),
    Config;
init_per_group(peer_handler, Config) ->
    NewConfig = [{stream_callback_mod, peer_test_handler},
                 {initial_window_size,99999999}|Config],
    chatterbox_test_buddy:start(NewConfig);
init_per_group(echo_handler, Config) ->
    NewConfig = [{stream_callback_mod, echo_handler},
                 {initial_window_size,99999999}|Config],
    chatterbox_test_buddy:start(NewConfig);
init_per_group(_, Config) -> Config.

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

send_body_opts(_Config) ->
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

    ExpectedResponseBody = <<"BodyPart1\nBodyPart2">>,

    {ok, {ResponseHeaders, ResponseBody}} = http2_client:sync_request(Client, RequestHeaders, <<>>),
    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    ?assertEqual(ExpectedResponseBody, iolist_to_binary(ResponseBody)),
    ok.

echo_body(_Config) ->
    {ok, Client} = http2_client:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"POST">>},
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],

    Body = <<"echo!echo!echo!echo!echo!">>,

    {ok, {ResponseHeaders,
          ResponseBody}} = http2_client:sync_request(Client, RequestHeaders,
                                                     Body),
    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    ?assertEqual(Body, iolist_to_binary(ResponseBody)),
    ok.


