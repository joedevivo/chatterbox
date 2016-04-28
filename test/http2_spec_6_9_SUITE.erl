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
    {H, _} =
        h2_frame_headers:to_frames(1,
                                   RequestHeaders,
                                   hpack:new_context(),
                                   16384,
                                   true),

    http2c:send_unaltered_frames(Client, H),

    Resp0 = http2c:wait_for_n_frames(Client, 1, 2),
    ct:pal("Resp0: ~p", [Resp0]),
    ?assertEqual(2, (length(Resp0))), % Should get one byte:

    [_RespHeaders, {Frame1H, _}] = Resp0,
    ?assertEqual(1, (Frame1H#frame_header.length)),

    http2c:send_unaltered_frames(
      Client,
      [
       {#frame_header{
           stream_id=1
          },
        h2_frame_window_update:new(1)
       }
      ]
     ),

    Resp1 = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp1: ~p", [Resp1]),
    ?assertEqual(1, (length(Resp1))),

    [{Frame2H, _}] = Resp1,
    ?assertEqual(1, (Frame2H#frame_header.length)),

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
        h2_frame_window_update:new(0)
       }
      ]),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, (GoAwayH#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_goaway:error_code(GoAway))),
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

    {[H], _} =
        h2_frame_headers:to_frames(1,
                                   RequestHeaders,
                                   hpack:new_context(),
                                   16384,
                                   false),

    http2c:send_unaltered_frames(
      Client,
      [H,
       {#frame_header{
           type=?WINDOW_UPDATE,
           length=24,
           stream_id=1
          },
        h2_frame_window_update:new(0)
       }
      ]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{RstStreamH, RstStream}] = Resp,
    ?assertEqual(?RST_STREAM, (RstStreamH#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_rst_stream:error_code(RstStream))),
    ok.

send_window_updates_greater_than_max(_Config) ->
    {ok, Client} = http2c:start_link(),

    F = {#frame_header{
            type=?WINDOW_UPDATE,
            length=24,
            stream_id=0
           },
         h2_frame_window_update:new(2147483647)
        },

    http2c:send_unaltered_frames(Client, [ F, F ]),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, (GoAwayH#frame_header.type)),
    ?assertEqual(?FLOW_CONTROL_ERROR, (h2_frame_goaway:error_code(GoAway))),
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

    {[H], _} =
        h2_frame_headers:to_frames(1,
                                   RequestHeaders,
                                   hpack:new_context(),
                                   16384,
                                   false),

    WU = {#frame_header{
            type=?WINDOW_UPDATE,
            length=24,
            stream_id=1
           },
         h2_frame_window_update:new(2147483647)
         },

    http2c:send_unaltered_frames(
      Client,
      [H, WU]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{RstStreamH, RstStream}] = Resp,
    ?assertEqual(?RST_STREAM, (RstStreamH#frame_header.type)),
    ?assertEqual(?FLOW_CONTROL_ERROR, (h2_frame_rst_stream:error_code(RstStream))),
    ok.

send_settings_initial_window_size_greater_than_max(_Config) ->
    {ok, Client} = http2c:start_link(),
    Bin = <<16#00,16#00,16#06,16#04,16#00,16#00,16#00,16#00,16#00,
            16#00,16#04,16#80,16#00,16#00,16#00>>,
    http2c:send_binary(Client, Bin),
    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{_GoAwayH, GoAway}] = Resp,
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, (GoAwayH#frame_header.type)),
    ?assertEqual(?FLOW_CONTROL_ERROR, (h2_frame_goaway:error_code(GoAway))),
    ok.
