-module(protocol_errors_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() -> [
    no_data_frame_on_zero,
    no_headers_frame_on_zero,
    no_priority_frame_on_zero,
    no_rst_stream_frame_on_zero,
    no_push_promise_frame_on_zero,
    no_continuation_frame_on_zero,
    no_settings_frame_on_non_zero,
    no_ping_frame_on_non_zero,
    no_goaway_frame_on_non_zero
].

init_per_testcase(_, Config) ->
    lager_common_test_backend:bounce(debug),
    Config0 = chatterbox_test_buddy:start(Config),
    Config0.

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

no_data_frame_on_zero(Config) ->
    one_frame({#frame_header{length=2,type=?DATA,stream_id=0}, #data{data = <<1,2>>}}, Config).

no_headers_frame_on_zero(Config) ->
    one_frame({#frame_header{length=2,type=?HEADERS,stream_id=0}, #headers{block_fragment = <<1,2>>}}, Config).

no_priority_frame_on_zero(Config) ->
    one_frame({#frame_header{length=5,type=?PRIORITY,stream_id=0}, #priority{exclusive=0, stream_id=1, weight=1}}, Config).

no_rst_stream_frame_on_zero(Config) ->
    one_frame({#frame_header{length=4,type=?RST_STREAM,stream_id=0}, #rst_stream{error_code=?PROTOCOL_ERROR}}, Config).

no_push_promise_frame_on_zero(Config) ->
    one_frame({#frame_header{length=2,type=?PUSH_PROMISE,stream_id=0}, #push_promise{promised_stream_id=100, block_fragment = <<1,2>>}}, Config).

no_continuation_frame_on_zero(Config) ->
    one_frame({#frame_header{length=2,type=?CONTINUATION,stream_id=0}, #continuation{block_fragment = <<1,2>>}}, Config).

no_settings_frame_on_non_zero(Config) ->
    one_frame({#frame_header{length=0,type=?SETTINGS,stream_id=1}, #settings{max_concurrent_streams=2, max_header_list_size=1024}}, Config).

no_ping_frame_on_non_zero(Config) ->
    one_frame({#frame_header{length=8,type=?PING,stream_id=1}, #ping{opaque_data = <<1:64>>}}, Config).

no_goaway_frame_on_non_zero(Config) ->
    one_frame({#frame_header{length=4,type=?GOAWAY,stream_id=1}, #goaway{last_stream_id=1,error_code = ?PROTOCOL_ERROR}}, Config).


one_frame(Frame, _Config) ->
    {ok, Client} = http2c:start_link(),
    http2c:send_unaltered_frames(Client, [Frame]),

    %% How do I get the response? Should be GOAWAY with PROTOCOL_ERROR
    timer:sleep(100),

    Resp = http2c:get_frames(Client, 0),
    ct:pal("Resp: ~p", [Resp]),

    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,
    ok.
