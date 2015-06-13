-module(http2_frame_size_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() -> [frame_too_big, euc].

init_per_testcase(_, Config) ->
    lager_common_test_backend:bounce(debug),
    Config0 = chatterbox_test_buddy:start(Config),
    Config0.

end_per_test_case(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

frame_too_big(_Config) ->
    {ok, Client} = http2c:start_link(),
    Frames = [
        {#frame_header{length=16392,type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=3}, #headers{block_fragment = <<1:131136>>}}
    ],
    http2c:send_unaltered_frames(Client, Frames),

    %% How do I get the response? Should be GOAWAY with FRAME_SIZE_ERROR
    timer:sleep(100),

    Resp = http2c:get_frames(Client, 0),
    ct:pal("Resp: ~p", [Resp]),

    ?assertEqual(1, length(Resp)),

    [{_GoAwayH, GoAway}] = Resp,
    ?FRAME_SIZE_ERROR = GoAway#goaway.error_code,

    ok.

euc(_Config) ->
    {ok, Client} = http2c:start_link(),

    Headers1 = [
               {<<":path">>, <<"/">>},
               {<<"user-agent">>, <<"my cool browser">>},
               {<<"x-custom-header">>, <<"some custom value">>}
              ],
    HeaderContext1 = hpack:new_encode_context(),
    {HeadersBin1, HeaderContext2} = hpack:encode(Headers1, HeaderContext1),

    Headers2 = [
               {<<":path">>, <<"/some_file.html">>},
               {<<"user-agent">>, <<"my cool browser">>},
               {<<"x-custom-header">>, <<"some custom value">>}
              ],
    {HeadersBin2, HeaderContext3} = hpack:encode(Headers2, HeaderContext2),

    Headers3 = [
               {<<":path">>, <<"/some_file.html">>},
               {<<"user-agent">>, <<"my cool browser">>},
               {<<"x-custom-header">>, <<"new value">>}
              ],
    {HeadersBin3, _HeaderContext4} = hpack:encode(Headers3, HeaderContext3),

    Frames = [
              {#frame_header{length=byte_size(HeadersBin1),type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=3},#headers{block_fragment=HeadersBin1}},
              {#frame_header{length=byte_size(HeadersBin2),type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=5},#headers{block_fragment=HeadersBin2}},
              {#frame_header{length=byte_size(HeadersBin3),type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=7},#headers{block_fragment=HeadersBin3}}
    ],

    http2c:send_unaltered_frames(Client, Frames),
    timer:sleep(100),

    Resp = http2c:get_frames(Client, 0),
    ?assertEqual(0, length(Resp)).
