-module(http2_spec_6_5_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_invalid_push_setting
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
