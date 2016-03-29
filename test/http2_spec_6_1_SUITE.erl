-module(http2_spec_6_1_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_data_with_invalid_pad_length
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_data_with_invalid_pad_length(_Config) ->

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

    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS bor ?FLAG_PADDED
        },
      #headers{
         block_fragment=HeadersBin
        }
     },

    http2c:send_unaltered_frames(Client, [HF]),
    http2c:send_binary(
      Client,
      <<16#00,16#00,16#05,16#00,16#0b,16#00,16#00,16#00,16#01,
        16#06,16#54,16#65,16#73,16#74>>),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_Header, Payload}] = Resp,
    ?PROTOCOL_ERROR = Payload#goaway.error_code,
    ok.
