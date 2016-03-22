-module(http2_spec_4_3_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_invalid_header_block_fragment
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_invalid_header_block_fragment(_Config) ->
    {ok, Client} = http2c:start_link(),

    %% Bad Header Block, Literal Header Field with Incremental
    %% Indexing without Length and String segment
    Bin = <<16#00,16#00,16#01,16#01,16#05,
            16#00,16#00,16#00,16#01,16#40>>,
    http2c:send_binary(Client, Bin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?COMPRESSION_ERROR = GoAway#goaway.error_code,
    ok.
