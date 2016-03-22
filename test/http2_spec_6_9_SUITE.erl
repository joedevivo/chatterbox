-module(http2_spec_6_9_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     send_window_update_with_zero
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

send_window_update_with_zero(_Config) ->
    {ok, Client} = http2c:start_link(),

    http2c:send_unaltered_frames(
      Client,
      [
       {#frame_header{
           type=?WINDOW_UPDATE,
           length=24,
           stream_id=0
          },
        #window_update{window_size_increment=0}}
      ]),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?PROTOCOL_ERROR = GoAway#goaway.error_code,
    ok.
