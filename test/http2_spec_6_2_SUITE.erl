-module(http2_spec_6_2_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_header_with_invalid_pad_length,
     sends_go_example
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_header_with_invalid_pad_length(_Config) ->

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

    {ok, {HeadersBin, _}} = hpack:encode(RequestHeaders, hpack:new_context()),
    L = byte_size(HeadersBin)+1,
    PaddedBin = <<L,HeadersBin/binary>>,

    F = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS bor ?FLAG_PADDED
        },
      #headers{
         block_fragment=PaddedBin
        }
     },
    http2c:send_unaltered_frames(Client, [F]),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_Header, Payload}] = Resp,
    ?PROTOCOL_ERROR = Payload#goaway.error_code,
    ok.

sends_go_example(_Config) ->

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

    {ok, {HeadersBin, _}} = hpack:encode(RequestHeaders, hpack:new_context()),
    L = byte_size(HeadersBin)+1,
    %_PaddedBin = <<L,HeadersBin/binary>>,


    {ok, Client} = http2c:start_link(),
    http2c:send_binary(Client, <<L:24,16#01,16#0d,16#00,16#00,16#00,16#01>>),
    %% Sending one byte is really bad!
    http2c:send_binary(Client, <<L>>),
    http2c:send_binary(Client, HeadersBin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_Header, Payload}] = Resp,
    ?PROTOCOL_ERROR = Payload#goaway.error_code,

    ok.
