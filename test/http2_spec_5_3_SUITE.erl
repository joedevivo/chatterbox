-module(http2_spec_5_3_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_header_frame_that_depends_on_itself,
     sends_priority_frame_that_depends_on_itself,
     sends_priority_frame_that_depends_on_itself_later
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_header_frame_that_depends_on_itself(_Config) ->
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
    L = byte_size(HeadersBin) + 5,
    F = {
      #frame_header{
         stream_id=1,
         length=L,
         flags=?FLAG_END_HEADERS bor ?FLAG_PRIORITY,
         type=?HEADERS
        },
      #headers{
         priority=#priority{
                     exclusive=0,
                     stream_id=1,
                     weight=1
                    },
         block_fragment=HeadersBin
        }
     },


    http2c:send_unaltered_frames(Client, [F]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_Header, Payload}] = Resp,
    ?PROTOCOL_ERROR = Payload#rst_stream.error_code,
    ok.

sends_priority_frame_that_depends_on_itself(_Config) ->
    {ok, Client} = http2c:start_link(),

    PriorityFrame =
        {#frame_header{
            stream_id=1,
            type=?PRIORITY,
            length=5
            },
         #priority{
            stream_id=1
           }
         },

    http2c:send_unaltered_frames(Client, [PriorityFrame]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_Header, Payload}] = Resp,
    ?PROTOCOL_ERROR = Payload#rst_stream.error_code,
    ok.

sends_priority_frame_that_depends_on_itself_later(_Config) ->
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
    L = byte_size(HeadersBin),
    F = {
      #frame_header{
         stream_id=1,
         length=L,
         flags=?FLAG_END_HEADERS,% bor ?FLAG_END_STREAM,
         type=?HEADERS
        },
      #headers{
         block_fragment=HeadersBin
        }
     },

    PriorityFrame =
        {#frame_header{
            stream_id=1,
            type=?PRIORITY,
            length=5
            },
         #priority{
            stream_id=1
           }
         },

    http2c:send_unaltered_frames(Client, [F, PriorityFrame]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_Header, Payload}] = Resp,
    ?PROTOCOL_ERROR = Payload#rst_stream.error_code,

    ok.
