-module(http2_spec_6_5_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_invalid_push_setting,
     sends_value_above_max_flow_control_window_size,
     sends_max_frame_size_too_small,
     sends_max_frame_size_too_big
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_invalid_push_setting(_Config) ->
    {ok, Client} = http2c:start_link(),

    %% Settings frame with SETTINGS_ENABLE_PUSH = 2
    Bin = <<16#00,16#00,16#06,16#04,16#00,16#00,16#00,16#00,16#00,
            16#00,16#02,16#00,16#00,16#00,16#02>>,
    http2c:send_binary(Client, Bin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,
    ok.

sends_value_above_max_flow_control_window_size(_Config) ->
    {ok, Client} = http2c:start_link(),
    Bin = <<16#00,16#00,16#06,16#04,16#00,16#00,16#00,16#00,16#00,
            16#00,16#04,16#80,16#00,16#00,16#00>>,
    http2c:send_binary(Client, Bin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?FLOW_CONTROL_ERROR = GoAway#goaway.error_code,
    ok.

sends_max_frame_size_too_small(_Config) ->
        {ok, Client} = http2c:start_link(),
    Bin = <<16#00,16#00,16#06,16#04,16#00,16#00,16#00,16#00,16#00,
            16#00,16#05,16#00,16#00,16#3f,16#ff>>,
    http2c:send_binary(Client, Bin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,
    ok.

sends_max_frame_size_too_big(_Config) ->
        {ok, Client} = http2c:start_link(),
    Bin = <<16#00,16#00,16#06,16#04,16#00,16#00,16#00,16#00,16#00,
            16#00,16#05,16#01,16#00,16#00,16#00>>,
    http2c:send_binary(Client, Bin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,
    ok.
