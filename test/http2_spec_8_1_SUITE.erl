-module(http2_spec_8_1_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_head_request,
     sends_second_headers_with_no_end_stream,
     sends_uppercase_headers,
     sends_pseudo_after_regular,
     sends_invalid_pseudo,
     sends_response_pseudo_with_request,
     sends_connection_header,
     sends_bad_TE_header,
     sends_double_pseudo,
     sends_invalid_content_length_single_frame,
     sends_invalid_content_length_multi_frame
    ].

init_per_suite(Config) ->
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_head_request(_Config) ->
    {ok, Client} = http2c:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"HEAD">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, {HeadersBin, _EC}} = hpack:encode(RequestHeaders, hpack:new_context()),
    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS bor ?FLAG_END_STREAM
        },
      #headers{
         block_fragment=HeadersBin
        }
     },
    http2c:send_unaltered_frames(Client, [HF]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{Header, _Payload}] = Resp,
    ?assertEqual(?HEADERS, Header#frame_header.type),
    ok.

sends_second_headers_with_no_end_stream(_Config) ->

    {ok, Client} = http2c:start_link(),

    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"trailer">>, <<"x-test">>}
        ],

    {ok, {HeadersBin, EC}} = hpack:encode(RequestHeaders, hpack:new_context()),

    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      #headers{
         block_fragment=HeadersBin
        }
     },

    Data = {
      #frame_header{
         stream_id=1,
         length=2
        },
      #data{
         data= <<"hi">>
        }
     },

    RequestTrailers =
        [
         {<<"x-test">>, <<"ok">>}
        ],
    {ok, {TrailersBin, _EC2}} = hpack:encode(RequestTrailers, EC),
    TF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      #headers{
         block_fragment=TrailersBin
        }
     },

    http2c:send_unaltered_frames(Client, [HF, Data, TF]),

    Resp = http2c:wait_for_n_frames(Client, 1, 2),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(2, length(Resp)),
    [_WindowUpdate,{Header, Payload}] = Resp,
    ?assertEqual(?RST_STREAM, Header#frame_header.type),
    ?assertEqual(?PROTOCOL_ERROR, Payload#rst_stream.error_code),
    ok.

sends_uppercase_headers(_Config) ->
    test_rst_stream(
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"X-TEST">>, <<"test">>}
        ]).

sends_pseudo_after_regular(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<":method">>, <<"GET">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]).

sends_invalid_pseudo(_Config) ->
    test_rst_stream(
        [
         {<<":anything">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]).

sends_response_pseudo_with_request(_Config) ->
    test_rst_stream(
        [
         {<<":status">>, <<"200">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]).

test_rst_stream(RequestHeaders) ->
    {ok, Client} = http2c:start_link(),
    {ok, {HeadersBin, _EC}} = hpack:encode(RequestHeaders, hpack:new_context()),
    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      #headers{
         block_fragment=HeadersBin
        }
     },
    http2c:send_unaltered_frames(Client, [HF]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{Header, Payload}] = Resp,
    ?assertEqual(?RST_STREAM, Header#frame_header.type),
    ?assertEqual(?PROTOCOL_ERROR, Payload#rst_stream.error_code),
    ok.

sends_connection_header(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"connection">>, <<"keep-alive">>}
        ]).

sends_bad_TE_header(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"te">>, <<"trailers, deflate">>}
        ]).

sends_double_pseudo(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),

    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),

    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),

    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),
    ok.

sends_invalid_content_length_single_frame(_Config) ->
    test_content_length(
      [{#frame_header{
           type=?DATA,
           flags=?FLAG_END_STREAM,
           length=8,
           stream_id=1
          }, #data{ data = <<1,2,3,4,5,6,7,8>>}}]).

sends_invalid_content_length_multi_frame(_Config) ->
    test_content_length(
      [{#frame_header{
           type=?DATA,
           length=8,
           stream_id=1
          }, #data{ data = <<1,2,3,4,5,6,7,8>>}},
       {#frame_header{
           type=?DATA,
           length=8,
           flags=?FLAG_END_STREAM,
           stream_id=1
          }, #data{ data = <<11,12,13,14,15,16,17,18>>}}
      ]).


test_content_length(DataFrames) ->
    RequestHeaders =
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"content-length">>, <<"0">>}
        ],

    {ok, Client} = http2c:start_link(),
    {ok, {HeadersBin, _EC}} = hpack:encode(RequestHeaders, hpack:new_context()),
    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      #headers{
         block_fragment=HeadersBin
        }
     },
    http2c:send_unaltered_frames(Client, [HF|DataFrames]),

    ExpectedFrameCount = 1 + length(DataFrames),

    Resp = http2c:wait_for_n_frames(Client, 1, ExpectedFrameCount),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(ExpectedFrameCount, length(Resp)),

    [ErrorFrame|WindowUpdates] = lists:reverse(Resp),
    {Header, Payload} = ErrorFrame,
    ?assertEqual(?RST_STREAM, Header#frame_header.type),
    ?assertEqual(?PROTOCOL_ERROR, Payload#rst_stream.error_code),

    ExpectedWUs = [
     {#frame_header{
         type=?WINDOW_UPDATE,
         length=4,
         stream_id=1
        },
      #window_update{
         window_size_increment=8
        }}
     || _ <- lists:seq(1,length(DataFrames))],


    WindowUpdates = ExpectedWUs,
    ok.
