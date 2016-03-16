-module(header_continuation_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() -> [
    basic_continuation,
    basic_continuation_end_stream_first,
    bad_frame_wrong_type_between_continuations,
    bad_frame_wrong_stream_between_continuations
].

init_per_testcase(_, Config) ->
    Config0 = chatterbox_test_buddy:start(Config),
    Config0.

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

basic_continuation(_Config) ->
    {ok, Client} = http2c:start_link(),

    %% build some headers
    Headers = [
               {<<":method">>, <<"GET">>},
               {<<":path">>, <<"/index.html">>},
               {<<":scheme">>, <<"http">>},
               {<<":authority">>, <<"localhost:8080">>},
               {<<"accept">>, <<"*/*">>},
               {<<"accept-encoding">>, <<"gzip, deflate">>},
               {<<"user-agent">>, <<"nghttp2/0.7.7">>}
              ],

    {ok, {HeadersBin, _NewContext}} = hpack:encode(Headers, hpack:new_context()),

    <<H1:8/binary,H2:8/binary,H3/binary>> = HeadersBin,

    Frames = [
              {#frame_header{length=8,type=?HEADERS,flags=?FLAG_END_STREAM,stream_id=3},#headers{block_fragment=H1}},
              {#frame_header{length=8,type=?CONTINUATION,stream_id=3},#continuation{block_fragment=H2}},
              {#frame_header{length=8,type=?CONTINUATION,flags=?FLAG_END_HEADERS,stream_id=3},#continuation{block_fragment=H3}}
    ],
    http2c:send_unaltered_frames(Client, Frames),

    Resp = http2c:wait_for_n_frames(Client, 3, 2),
    cthr:pal("Resp: ~p", [Resp]),

    ?assertEqual(2, length(Resp)),
    ok.


basic_continuation_end_stream_first(_Config) ->
    {ok, Client} = http2c:start_link(),

    %% build some headers
    Headers = [
               {<<":method">>, <<"GET">>},
               {<<":path">>, <<"/index.html">>},
               {<<":scheme">>, <<"http">>},
               {<<":authority">>, <<"localhost:8080">>},
               {<<"accept">>, <<"*/*">>},
               {<<"accept-encoding">>, <<"gzip, deflate">>},
               {<<"user-agent">>, <<"nghttp2/0.7.7">>}
              ],

    {ok, {HeadersBin, _NewContext}} = hpack:encode(Headers, hpack:new_context()),

    <<H1:8/binary,H2:8/binary,H3/binary>> = HeadersBin,

    Frames = [
              {#frame_header{length=8,type=?HEADERS,flags=?FLAG_END_STREAM,stream_id=3},#headers{block_fragment=H1}},
              {#frame_header{length=8,type=?CONTINUATION,stream_id=3},#continuation{block_fragment=H2}},
              {#frame_header{length=8,type=?CONTINUATION,flags=?FLAG_END_HEADERS,stream_id=3},#continuation{block_fragment=H3}}
    ],
    http2c:send_unaltered_frames(Client, Frames),

    Resp = http2c:wait_for_n_frames(Client, 3, 2),
    cthr:pal("Resp: ~p", [Resp]),
    ?assertEqual(2, length(Resp)),
    ok.


bad_frame_wrong_type_between_continuations(_Config) ->
    {ok, Client} = http2c:start_link(),

    %% build some headers
    Headers = [
               {<<":method">>, <<"GET">>},
               {<<":path">>, <<"/index.html">>},
               {<<":scheme">>, <<"http">>},
               {<<":authority">>, <<"localhost:8080">>},
               {<<"accept">>, <<"*/*">>},
               {<<"accept-encoding">>, <<"gzip, deflate">>},
               {<<"user-agent">>, <<"nghttp2/0.7.7">>}
              ],

    {ok, {HeadersBin, _NewContext}} = hpack:encode(Headers, hpack:new_context()),

    <<H1:8/binary,H2:8/binary,H3/binary>> = HeadersBin,

    Frames = [
              {#frame_header{length=8,type=?HEADERS,stream_id=3},#headers{block_fragment=H1}},
              {#frame_header{length=8,type=?CONTINUATION,stream_id=3},#continuation{block_fragment=H2}},
              {#frame_header{length=8,type=?HEADERS,stream_id=3},#headers{block_fragment=H1}},
              {#frame_header{length=8,type=?CONTINUATION,flags=?FLAG_END_HEADERS,stream_id=3},#continuation{block_fragment=H3}}
    ],
    http2c:send_unaltered_frames(Client, Frames),

    Resp = http2c:wait_for_n_frames(Client, 3, 0),
    cthr:pal("Resp: ~p", [Resp]),
    ?assertEqual(0, length(Resp)),
    Resp2 = http2c:wait_for_n_frames(Client, 0, 1),
    1 = length(Resp2),

    [{_GoAwayH, GoAway}] = Resp2,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,
    ok.

bad_frame_wrong_stream_between_continuations(_Config) ->
    {ok, Client} = http2c:start_link(),

    %% build some headers
    Headers = [
               {<<":method">>, <<"GET">>},
               {<<":path">>, <<"/index.html">>},
               {<<":scheme">>, <<"http">>},
               {<<":authority">>, <<"localhost:8080">>},
               {<<"accept">>, <<"*/*">>},
               {<<"accept-encoding">>, <<"gzip, deflate">>},
               {<<"user-agent">>, <<"nghttp2/0.7.7">>}
              ],

    {ok, {HeadersBin, _NewContext}} = hpack:encode(Headers, hpack:new_context()),

    <<H1:8/binary,H2:8/binary,H3/binary>> = HeadersBin,

    Frames = [
              {#frame_header{length=8,type=?HEADERS,stream_id=3},#headers{block_fragment=H1}},
              {#frame_header{length=8,type=?CONTINUATION,stream_id=3},#continuation{block_fragment=H2}},
              {#frame_header{length=8,type=?HEADERS,stream_id=5},#headers{block_fragment=H1}},
              {#frame_header{length=8,type=?CONTINUATION,flags=?FLAG_END_HEADERS,stream_id=3},#continuation{block_fragment=H3}}
    ],
    http2c:send_unaltered_frames(Client, Frames),

    Resp = http2c:wait_for_n_frames(Client, 3, 0),
    cthr:pal("Resp: ~p", [Resp]),

    ?assertEqual(0, length(Resp)),

    Resp2 = http2c:wait_for_n_frames(Client, 0, 1),

    1 = length(Resp2),

    [{_GoAwayH, GoAway}] = Resp2,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,
    ok.
