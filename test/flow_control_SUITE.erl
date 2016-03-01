-module(flow_control_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     exceed_server_connection_receive_window,
     exceed_server_stream_receive_window
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    Config.

init_per_testcase(
  exceed_server_connection_receive_window,
  Config) ->

    PreChatterConfig =
        [
         {stream_callback_mod, server_connection_receive_window},
         {initial_window_size, 64}
        |Config],
    PostChatter = chatterbox_test_buddy:start(PreChatterConfig),
    PostChatter;
init_per_testcase(
  exceed_server_stream_receive_window,
  Config) ->

    PreChatterConfig =
        [
         {stream_callback_mod, server_stream_receive_window},
         {initial_window_size, 64}
        |Config],
    PostChatter = chatterbox_test_buddy:start(PreChatterConfig),
    PostChatter;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

exceed_server_connection_receive_window(_Config) ->
    Client = send_65bytes(),
    %% Check for GO_AWAY
    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),

    1 = length(Resp),

    [{#frame_header{type=?GOAWAY}, GoAway}] = Resp,
    ?FLOW_CONTROL_ERROR = GoAway#goaway.error_code,

    ok.

exceed_server_stream_receive_window(_Config) ->
    Client = send_65bytes(),

    %% First, pull off the window update frame we got on stream 0,
    [WindowUpdate] = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Expected window update, and got ~p", [WindowUpdate]),
    %% now challenge that
    {#frame_header{}, #window_update{}} = WindowUpdate,

    %% Check for RST_STREAM
    Resp = http2c:wait_for_n_frames(Client, 3, 1),
    ct:pal("Resp: ~p", [Resp]),

    1 = length(Resp),

    [{#frame_header{type=?RST_STREAM}, RstStream}] = Resp,
    ?FLOW_CONTROL_ERROR = RstStream#rst_stream.error_code,
    ok.


send_65bytes() ->
    %% We're up and running with a ridiculously small connection
    %% window size of 64 bytes. The problem is that each stream will
    %% have a recv window size of 64 bytes also, so both conditions
    %% will be violated.

    %% Also, a good client will not ever try and exceed the window
    %% size, so we're going to use http2c to misbehave
    {ok, Client} = http2c:start_link(),

    %% Let's make a request:
    Headers =
        [
         {<<":path">>, <<"/">>},
         {<<":method">>, <<"POST">>}
        ],
    {HeadersBin, _EncodeContext} = hpack:encode(Headers, hpack:new_encode_context()),

    HeaderFrame = {#frame_header{
                      length=byte_size(HeadersBin),
                      type=?HEADERS,
                      flags=?FLAG_END_HEADERS,
                      stream_id=3
                     },
                   #headers{block_fragment=HeadersBin}},

    http2c:send_unaltered_frames(Client, [HeaderFrame]),
    %% If the server_connection_receive_window callback_mod worked,
    %% this headers frame should have increased the stream's recv
    %% window, but not the connections

    %% So now, send 65 bytes and we should get a connection level flow
    %% control error
    DataFrame = {
      #frame_header{
         length=65,
         type=?DATA,
         flags=?FLAG_END_STREAM,
         stream_id=3
         },
      #data{
         data = crypto:rand_bytes(65)
        }
     },
    http2c:send_unaltered_frames(Client, [DataFrame]),

    Client.

%% TODO: Tests for sending data when send_*_window is too small
