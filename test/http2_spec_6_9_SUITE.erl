-module(http2_spec_6_9_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     send_window_update,
     send_window_update_with_zero,
     send_window_update_with_zero_on_stream,
     send_window_updates_greater_than_max,
     send_window_updates_greater_than_max_on_stream,
     send_settings_initial_window_size_greater_than_max
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

send_window_update(_Config) ->
    {ok, Client} = http2c:start_link(),

    %% Send settings initial window size = 1
    http2c:send_binary(
      Client,
      <<0,0,6,?SETTINGS,0,0,0,0,0,0,?SETTINGS_INITIAL_WINDOW_SIZE/binary,0,0,0,1>>
     ),

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

    {{FH, FP}, _} = http2_frame_headers:to_frame(1, RequestHeaders, hpack:new_context()),

    http2c:send_unaltered_frames(Client, [{FH#frame_header{flags=?FLAG_END_HEADERS bor ?FLAG_END_STREAM}, FP}]),

    Resp0 = http2c:wait_for_n_frames(Client, 1, 2),
    ct:pal("Resp0: ~p", [Resp0]),
    ?assertEqual(2, length(Resp0)), % Should get one byte:

    [_RespHeaders, {Frame1H, _}] = Resp0,
    ?assertEqual(1, Frame1H#frame_header.length),

    http2c:send_unaltered_frames(
      Client,
      [
       {#frame_header{
           stream_id=1
          },
        #window_update{
           window_size_increment=1}}
      ]
     ),

    Resp1 = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp1: ~p", [Resp1]),
    ?assertEqual(1, length(Resp1)),

    [{Frame2H, _}] = Resp1,
    ?assertEqual(1, Frame2H#frame_header.length),

    ok.


send_window_update_with_zero(_Config) ->
    {ok, Client} = http2c:start_link(),

    http2c:send_unaltered_frames(
      Client,
      [
       {#frame_header{
           type=?WINDOW_UPDATE,
           length=24,
           stream_id=0
          },
        #window_update{window_size_increment=0}}
      ]),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_H, GoAway}] = Resp,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,

    ok.

send_window_update_with_zero_on_stream(_Config) ->
    {ok, Client} = http2c:start_link(),

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

    {F, _} = http2_frame_headers:to_frame(1, RequestHeaders, hpack:new_context()),


    http2c:send_unaltered_frames(
      Client,
      [F,
       {#frame_header{
           type=?WINDOW_UPDATE,
           length=24,
           stream_id=1
          },
        #window_update{window_size_increment=0}}
      ]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_H, RstStream}] = Resp,
    ?PROTOCOL_ERROR = RstStream#rst_stream.error_code,
    ok.

send_window_updates_greater_than_max(_Config) ->
    {ok, Client} = http2c:start_link(),

    F = {#frame_header{
            type=?WINDOW_UPDATE,
            length=24,
            stream_id=0
           },
         #window_update{window_size_increment=2147483647}},

    http2c:send_unaltered_frames(Client, [ F, F ]),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?FLOW_CONTROL_ERROR = GoAway#goaway.error_code,
    ok.

send_window_updates_greater_than_max_on_stream(_Config) ->
    {ok, Client} = http2c:start_link(),

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

    {F1, _} = http2_frame_headers:to_frame(1, RequestHeaders, hpack:new_context()),
    F2 = {#frame_header{
            type=?WINDOW_UPDATE,
            length=24,
            stream_id=1
           },
         #window_update{window_size_increment=2147483647}},

    http2c:send_unaltered_frames(
      Client,
      [F1, F2]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_H, RstStream}] = Resp,
    ?FLOW_CONTROL_ERROR = RstStream#rst_stream.error_code,
    ok.

send_settings_initial_window_size_greater_than_max(_Config) ->
    {ok, Client} = http2c:start_link(),
    Bin = <<16#00,16#00,16#06,16#04,16#00,16#00,16#00,16#00,16#00,
            16#00,16#04,16#80,16#00,16#00,16#00>>,
    http2c:send_binary(Client, Bin),
    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?FLOW_CONTROL_ERROR = GoAway#goaway.error_code,
    ok.
