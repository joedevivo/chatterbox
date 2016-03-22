-module(http2_spec_5_5_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_unknown_extension_frame
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_unknown_extension_frame(_Config) ->
    {ok, Client} = http2c:start_link(),


    %% Some FF type frame that doesn't exist
    Bin = <<16#00,16#00,16#01,16#ff,16#00,16#00,16#00,16#00,16#00,
            16#00>>,
    http2c:send_binary(Client, Bin),

    %% It should be ignored, so let's send a ping and get one back
    http2c:send_unaltered_frames(Client,
                                 [
                                  {#frame_header{
                                      type=?PING,
                                      stream_id=0,
                                      length=8
                                     },
                                   #ping{
                                      opaque_data= crypto:rand_bytes(8)
                                     }}
                                 ]),


    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{PingH, _PingBody}] = Resp,
    ?PING = PingH#frame_header.type,
    ok.
