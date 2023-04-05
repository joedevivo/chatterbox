-module(http2_spec_5_1_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_rst_stream_to_idle,
     %half_closed_remote_sends_headers,
     closed_receives_headers,
     sends_window_update_to_idle,
     client_sends_even_stream_id,
     exceeds_max_concurrent_streams,
     total_streams_above_max_concurrent
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(total_streams_above_max_concurrent, Config) ->
    chatterbox_test_buddy:start(
      [
       {max_concurrent_streams, 10},
       {enable_push, 0}
       |Config]
     );
init_per_testcase(exceeds_max_concurrent_streams, Config) ->
    chatterbox_test_buddy:start(
      [
       {max_concurrent_streams, 10},
       {enable_push, 0}
       |Config]
     );
init_per_testcase(_, Config) ->
    chatterbox_test_buddy:start(Config).

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

total_streams_above_max_concurrent(Config) ->
    MaxConcurrent = ?config(max_concurrent_streams, Config),

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

    StreamIds = lists:seq(1,MaxConcurrent*2,2),

    %% See Caine/Hackman Theory
    AStreamTooFar = 1 + MaxConcurrent*2,

    FinalEC =
        lists:foldl(
          fun(StreamId, EncodeContext) ->
                  {H1, NewEC} =
                      h2_frame_headers:to_frames(
                     StreamId,
                     RequestHeaders,
                     EncodeContext,
                     16384,
                     true),
                  http2c:send_unaltered_frames(Client, H1),
                  NewEC
          end,
          hpack:new_context(),
          StreamIds
         ),
    timer:sleep(100),

    %% We should have a series of responses now, and zero streams
    %% should be open

    Resp0 = http2c:get_frames(Client,0),
    ?assertEqual([], Resp0),
    [ begin
          [{FH1,_FB1},{FH2,_FB2}] = http2c:get_frames(Client, StreamId),
         ?assertEqual(StreamId, (FH1#frame_header.stream_id)),
         ?assertEqual(?HEADERS, (FH1#frame_header.type)),
         ?assertEqual(StreamId, (FH2#frame_header.stream_id)),
         ?assertEqual(?DATA, (FH2#frame_header.type))
     end || StreamId <- StreamIds],

    %% Now, open AStreamTooFar
    {HFinal, _UnusedEC} =
        h2_frame_headers:to_frames(
       AStreamTooFar,
       RequestHeaders,
       FinalEC,
       16384,
       true),
    http2c:send_unaltered_frames(Client, HFinal),

    %% Response should be a real response, because we haven't exceeded
    %% anything
    Response = http2c:wait_for_n_frames(Client, AStreamTooFar, 2),
    ?assertEqual(2, (length(Response))),

    [{RH1,_RB1},{RH2,_RB2}] = Response,
    ?assertEqual(AStreamTooFar, (RH1#frame_header.stream_id)),
    ?assertEqual(?HEADERS, (RH1#frame_header.type)),
    ?assertEqual(AStreamTooFar, (RH2#frame_header.stream_id)),
    ?assertEqual(?DATA, (RH2#frame_header.type)),
    ok.

exceeds_max_concurrent_streams(Config) ->
    MaxConcurrent = ?config(max_concurrent_streams, Config),

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

    StreamIds = lists:seq(1,MaxConcurrent*2,2),

    AStreamTooFar = 1 + MaxConcurrent*2,

    FinalEC =
        lists:foldl(
          fun(StreamId, EncodeContext) ->
                  {H1, NewEC} =
                      h2_frame_headers:to_frames(
                     StreamId,
                     RequestHeaders,
                     EncodeContext,
                     16384,
                     false),
                  http2c:send_unaltered_frames(Client, H1),
                  NewEC
          end,
          hpack:new_context(),
          StreamIds
         ),
    timer:sleep(200),
    %% Now Max Streams should be open, but let's make sure we haven't
    %% heard back from anyone

    Resp0 = http2c:get_frames(Client,0),
    ?assertEqual([], Resp0),
    [ begin
          Resp = http2c:get_frames(Client, StreamId),
          ?assertEqual([], Resp)
      end || StreamId <- StreamIds],

    %% Now, open AStreamTooFar

    {HFinal, _UnusedEC} =
        h2_frame_headers:to_frames(
       AStreamTooFar,
       RequestHeaders,
       FinalEC,
       16384,
       false),
    http2c:send_unaltered_frames(Client, HFinal),

    %% Response should be RST_STREAM ?REFUSED_STREAM
    Response = http2c:wait_for_n_frames(Client, AStreamTooFar, 1),
    ?assertEqual(1, (length(Response))),
    [{RstH, RstP}] = Response,
    ?assertEqual(?RST_STREAM, (RstH#frame_header.type)),
    ?assertEqual(?REFUSED_STREAM, (h2_frame_rst_stream:error_code(RstP))),
    ok.

sends_rst_stream_to_idle(_Config) ->
    {ok, Client} = http2c:start_link(),

    RstStream = h2_frame_rst_stream:new(?CANCEL),
    RstStreamBin = h2_frame:to_binary(
                  {#frame_header{
                      stream_id=1
                     },
                   RstStream}),

    http2c:send_binary(Client, RstStreamBin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{_GoAwayH, GoAway}] = Resp,
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_goaway:error_code(GoAway))),
    ok.

half_closed_remote_sends_headers(_Config) ->
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

    {H1, EC} =
        h2_frame_headers:to_frames(1,
                                   RequestHeaders,
                                   hpack:new_context(),
                                   16384,
                                   true),

    http2c:send_unaltered_frames(Client, H1),

    %% The stream should be half closed remote now

    {H2, _EC2} =
        h2_frame_headers:to_frames(1,
                                   RequestHeaders,
                                   EC,
                                   16384,
                                   true),


    http2c:send_unaltered_frames(Client, H2),
    Resp = http2c:wait_for_n_frames(Client, 1, 2),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(true, (length(Resp) >= 1)),

    %% We need to find if one of these things are a RstStream
    RstStreams =
        lists:filter(
          fun({#frame_header{type=?RST_STREAM},_}) ->
                  true;
             (_) -> false
          end,
          Resp),
    ?assert(length(RstStreams) > 0),
    {RstStreamH, RstStream} = hd(RstStreams),
    ?assertEqual(?RST_STREAM, (RstStreamH#frame_header.type)),
    ?assertEqual(?STREAM_CLOSED, (h2_frame_rst_stream:error_code(RstStream))),
    ok.

closed_receives_headers(_Config) ->
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

    {H1, EC} =
        h2_frame_headers:to_frames(1,
                                   RequestHeaders,
                                   hpack:new_context(),
                                   16384,
                                   true),

    http2c:send_unaltered_frames(Client, H1),

    Resp = http2c:wait_for_n_frames(Client, 1, 2),
    ct:pal("Resp: ~p", [Resp]),

    %% The stream should be closed now

    {H2, _EC2} =
        h2_frame_headers:to_frames(1,
                                   RequestHeaders,
                                   EC,
                                   16384,
                                   true),

    http2c:send_unaltered_frames(Client, H2),
    RstResp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("RstResp: ~p", [RstResp]),
    ?assertEqual(true, (length(RstResp) >= 1)),

    %% We need to find if one of these things are a RstStream
    RstStreams =
        lists:filter(
          fun({#frame_header{type=?RST_STREAM},_}) ->
                  true;
             (_) -> false
          end,
          RstResp),
    ?assert(length(RstStreams) > 0),
    {RstStreamH, RstStream} = hd(RstStreams),
    ?assertEqual(?RST_STREAM, (RstStreamH#frame_header.type)),
    ?assertEqual(?STREAM_CLOSED, (h2_frame_rst_stream:error_code(RstStream))),
    ok.

sends_window_update_to_idle(_Config) ->
    {ok, Client} = http2c:start_link(),
    WUBin = h2_frame:to_binary(
                  {#frame_header{
                      stream_id=1
                     },
                   h2_frame_window_update:new(1)
                   }),

    http2c:send_binary(Client, WUBin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, (GoAwayH#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_goaway:error_code(GoAway))),
    ok.

client_sends_even_stream_id(_Config) ->
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

    {H, _} =
        h2_frame_headers:to_frames(2,
                                   RequestHeaders,
                                   hpack:new_context(),
                                   16384,
                                   false),

    http2c:send_unaltered_frames(Client, H),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, (GoAwayH#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_goaway:error_code(GoAway))),
    ok.
