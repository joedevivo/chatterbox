-module(http2_frame_size_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() -> [
  frame_too_big,
  euc
%% TODO: Tests break because I'm having trouble sending broken data.
%  wrong_size_priority,
%  wrong_size_rst_stream,
%  wrong_size_ping,
%  wrong_size_window_update
].

init_per_testcase(_, Config) ->
    Config0 = chatterbox_test_buddy:start(Config),
    Config0.

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

wrong_size_priority(Config) ->
    send_wrong_size(?PRIORITY, Config).
wrong_size_rst_stream(Config) ->
    send_wrong_size(?RST_STREAM, Config).
wrong_size_ping(Config) ->
    send_wrong_size(?PING, Config).
wrong_size_window_update(Config) ->
    send_wrong_size(?WINDOW_UPDATE, Config).

send_wrong_size(Type, _Config) ->
    {ok, Client} = http2c:start_link(),
    http2c:send_binary(Client, <<10:24,Type:8,0:1,0:31,0:100>>),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),

    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?FRAME_SIZE_ERROR = GoAway#goaway.error_code,
    ok.

frame_too_big(_Config) ->
    {ok, Client} = http2c:start_link(),
    Frames = [
        {
          #frame_header{
             length=16392,
             type=?HEADERS,
             flags=?FLAG_END_HEADERS,
             stream_id=3},
          #headers{block_fragment = <<1:131136>>}}
    ],
    http2c:send_unaltered_frames(Client, Frames),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
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
    HeaderContext1 = hpack:new_context(),
    {ok, {HeadersBin1, HeaderContext2}} = hpack:encode(Headers1, HeaderContext1),

    Headers2 = [
               {<<":path">>, <<"/some_file.html">>},
               {<<"user-agent">>, <<"my cool browser">>},
               {<<"x-custom-header">>, <<"some custom value">>}
              ],
    {ok, {HeadersBin2, HeaderContext3}} = hpack:encode(Headers2, HeaderContext2),

    Headers3 = [
               {<<":path">>, <<"/some_file.html">>},
               {<<"user-agent">>, <<"my cool browser">>},
               {<<"x-custom-header">>, <<"new value">>}
              ],
    {ok, {HeadersBin3, _HeaderContext4}} = hpack:encode(Headers3, HeaderContext3),

    Frames = [
              {#frame_header{length=byte_size(HeadersBin1),type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=3},#headers{block_fragment=HeadersBin1}},
              {#frame_header{length=byte_size(HeadersBin2),type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=5},#headers{block_fragment=HeadersBin2}},
              {#frame_header{length=byte_size(HeadersBin3),type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=7},#headers{block_fragment=HeadersBin3}}
    ],

    http2c:send_unaltered_frames(Client, Frames),

    Resp = http2c:wait_for_n_frames(Client, 0, 0),
    ?assertEqual(0, length(Resp)).
