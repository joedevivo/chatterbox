-module(http2_frame_size_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() -> [frame_too_big].

init_per_testcase(_, Config) ->
    lager_common_test_backend:bounce(debug),
    Config0 = chatterbox_test_buddy:start(Config),
    Config0.

end_per_test_case(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

frame_too_big(Config) ->
    {ok, Client} = http2c:start_link(),
    Frames = [
        {#frame_header{length=16392,type=?HEADERS,flags=?FLAG_END_HEADERS,stream_id=3}, #headers{block_fragment = <<1:131136>>}}
    ],
    http2c:send_unaltered_frames(Client, Frames),

    %% How do I get the response? Should be GOAWAY with FRAME_SIZE_ERROR
    timer:sleep(10000),

    Resp = http2c:get_frames(Client, 3),
    ct:pal("Resp: ~p", [Resp]),

    ?assertEqual(1, length(Resp)),
    ok.
