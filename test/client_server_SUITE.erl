-module(client_server_SUITE).

-include("http2.hrl").

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
                                 basic_push,
                                 connect_timeout]},
             {peer_handler, [get_peer_in_handler]},
             {double_body_handler, [send_body_opts]},
             {echo_handler, [echo_body,
                             large_body]}
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
    NewConfig = [{stream_callback_mod, echo_handler}|Config],
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
    {ok, Client} = h2_client:start_link(),
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
    {ok, {ResponseHeaders, ResponseBody, _Trailers}} = h2_client:sync_request(Client, RequestHeaders, <<>>),

    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),

    ok.

upgrade_tcp_connection(_Config) ->
    %% TODO Why don't the options of keyfile/certfile/cacertfile work here
    %% but instead we have to turn off verification?
    {ok, Client} = h2_client:start_ssl_upgrade_link("localhost", 8081, <<>>, [{verify, verify_none}]),

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
    {ok, {ResponseHeaders, ResponseBody, _Trailers}} = h2_client:sync_request(Client, RequestHeaders, <<>>),
    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    ok.


basic_push(_Config) ->
    {ok, Client} = h2_client:start_link(),
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
    {ok, {ResponseHeaders, _ResponseBody, _Trailers}} = h2_client:sync_request(Client, RequestHeaders, <<>>),

    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    %ct:pal("Response Body: ~p", [ResponseBody]),

    %% Give it time to deliver pushes
    %% We'll know we're done when we're notified of all the streams ending.
    wait_for_n_notifications(12),

    timer:sleep(1000),

    Streams = Client,
    ct:pal("Streams ~p", [Streams]),
    ?assertEqual(0, (h2_stream_set:my_active_count(Streams))),
    %?assertEqual(0, (h2_stream_set:their_active_count(Streams))),

    MyActiveStreams = h2_stream_set:my_active_streams(Streams),
    ct:pal("my active ~p", [MyActiveStreams]),
    ?assertEqual(0, (length(MyActiveStreams))), %% This closed stream should be GC'ed

    TheirActiveStreams = h2_stream_set:their_active_streams(Streams),
    ct:pal("my active ~p", [TheirActiveStreams]),
    ?assertEqual(12, (length(TheirActiveStreams))),

    [?assertEqual(closed, (h2_stream_set:type(S))) || S <- TheirActiveStreams],
    ok.

wait_for_n_notifications(0) ->
    ok;
wait_for_n_notifications(N) ->
    ct:pal("test waiting for END_STREAM on ~p", [self()]),
    receive
        {'END_STREAM', _} ->
            ct:pal("got END_STREAM ~p", [N]),
            wait_for_n_notifications(N-1);
        _ ->
            wait_for_n_notifications(N)
    after
        2000 ->
            ok
    end.

connect_timeout(_Config) ->
    {ok, Port} = application:get_env(chatterbox, port),
    ?assertMatch({error, {shutdown, timeout}},
                 h2_client:start(http, "localhost", Port, [], #{connect_timeout => 0})),
    ok.

get_peer_in_handler(_Config) ->
    {ok, Client} = h2_client:start_link(),
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


    {ok, {ResponseHeaders, ResponseBody, _Trailers}} = h2_client:sync_request(Client, RequestHeaders, <<>>),
    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    ok.

send_body_opts(_Config) ->
    {ok, Client} = h2_client:start_link(),
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

    {ok, {ResponseHeaders, ResponseBody, _Trailers}} = h2_client:sync_request(Client, RequestHeaders, <<>>),
    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseBody]),
    ?assertEqual(ExpectedResponseBody, (iolist_to_binary(ResponseBody))),
    ok.

echo_body(_Config) ->
    {ok, Client} = http2c:start_link(),
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

    {ok, {HeadersBin, _EncodeContext}} = hpack:encode(RequestHeaders, hpack:new_context()),

    HeaderFrame = {#frame_header{
                      length=byte_size(HeadersBin),
                      type=?HEADERS,
                      flags=?FLAG_END_HEADERS,
                      stream_id=3
                     },
                   h2_frame_headers:new(HeadersBin)
                  },

    http2c:send_unaltered_frames(Client, [HeaderFrame]),

    Body = crypto:strong_rand_bytes(128),
    BodyFrames = h2_frame_data:to_frames(3, Body, #settings{max_frame_size=64}),
    http2c:send_unaltered_frames(Client, BodyFrames),

    timer:sleep(300),
    Frames = http2c:get_frames(Client, 3),
    DataFrames = lists:filter(fun({#frame_header{type=?DATA}, _}) -> true;
                                 (_) -> false end, Frames),
    ResponseData = lists:map(fun({_, DataP}) ->
                                     h2_frame_data:data(DataP)
                             end, DataFrames),
    io:format("Body: ~p, response: ~p~n", [Body, ResponseData]),
    ?assertEqual(Body, (iolist_to_binary(ResponseData))),
    ok.

large_body(_Config) ->
    {ok, Client} = http2c:start_link(),
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

    {ok, {HeadersBin, _EncodeContext}} = hpack:encode(RequestHeaders, hpack:new_context()),

    HeaderFrame = {#frame_header{
                      length=byte_size(HeadersBin),
                      type=?HEADERS,
                      flags=?FLAG_END_HEADERS,
                      stream_id=3
                     },
                   h2_frame_headers:new(HeadersBin)
                  },

    http2c:send_unaltered_frames(Client, [HeaderFrame]),

    Body = crypto:strong_rand_bytes(32828),
    BodyFrames = h2_frame_data:to_frames(3, Body, #settings{max_frame_size=16384}),
    http2c:send_unaltered_frames(Client, BodyFrames),

    timer:sleep(300),
    Frames = http2c:get_frames(Client, 3),
    DataFrames = lists:filter(fun({#frame_header{type=?DATA}, _}) -> true;
                                 (_) -> false end, Frames),
    ResponseData = lists:map(fun({_, DataP}) ->
                                     h2_frame_data:data(DataP)
                             end, DataFrames),
    io:format("response: ~p~n", [ResponseData]),
    ?assertEqual(size(Body), iolist_size(ResponseData)),
    ok.
