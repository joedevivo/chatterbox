-module(http2_spec_8_1_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_second_headers_with_no_end_stream,
     sends_uppercase_headers,
     sends_pseudo_after_regular
    ].

init_per_suite(Config) ->
%%    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
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
         {<<"X-TEST">>, <<"test">>}
        ],

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

sends_pseudo_after_regular(_Config) ->
    {ok, Client} = http2c:start_link(),
    RequestHeaders =
        [
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<":method">>, <<"GET">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],

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
