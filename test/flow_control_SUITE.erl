-module(flow_control_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     exceed_server_connection_receive_window,
     exceed_server_stream_receive_window,
     server_buffer_response
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(
  exceed_server_connection_receive_window,
  Config) ->

    PreChatterConfig =
        [
         {stream_callback_mod, server_connection_receive_window},
         {initial_window_size, ?DEFAULT_INITIAL_WINDOW_SIZE},
         {flow_control, manual}
        |Config],
    chatterbox_test_buddy:start(PreChatterConfig);

init_per_testcase(
  exceed_server_stream_receive_window,
  Config) ->

    PreChatterConfig =
        [
         {stream_callback_mod, server_stream_receive_window},
         {initial_window_size, 64},
         {flow_control, manual}
        |Config],
    chatterbox_test_buddy:start(PreChatterConfig);
init_per_testcase(server_buffer_response, Config) ->
    PreChatterConfig =
        [
         {stream_callback_mod, flow_control_handler},
         {initial_window_size, 64},
         {flow_control, manual}
        |Config],
    chatterbox_test_buddy:start(PreChatterConfig);
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

exceed_server_connection_receive_window(_Config) ->
    Client = send_n_bytes(?DEFAULT_INITIAL_WINDOW_SIZE + 1),
    %% Check for GO_AWAY
    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),

    ?assertEqual(1, (length(Resp))),
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, (GoAwayH#frame_header.type)),
    ?assertEqual(?FLOW_CONTROL_ERROR, (h2_frame_goaway:error_code(GoAway))),
    ok.

exceed_server_stream_receive_window(_Config) ->
    Client = send_n_bytes(65),

    %% First, pull off the window update frame we got on stream 0,
    [WindowUpdate] = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Expected window update, and got ~p", [WindowUpdate]),
    %% now challenge that

    {WUH, _} = WindowUpdate,
    ?assertEqual(?WINDOW_UPDATE, (WUH#frame_header.type)),

    %% Check for RST_STREAM
    Resp = http2c:wait_for_n_frames(Client, 3, 1),
    ct:pal("Resp: ~p", [Resp]),

    ?assertEqual(1, (length(Resp))),
    [{RstStreamH, RstStream}] = Resp,
    ?assertEqual(?RST_STREAM, (RstStreamH#frame_header.type)),
    ?assertEqual(?FLOW_CONTROL_ERROR, (h2_frame_rst_stream:error_code(RstStream))),
    ok.

server_buffer_response(_Config) ->
    WindowSize = 64,
    application:load(chatterbox),
    application:set_env(chatterbox, client_initial_window_size, WindowSize),
    Headers = [{<<":path">>, <<"/">>},
               {<<":method">>, <<"GET">>}],
    {ok, Client} = http2c:start_link(),
    {ok, {HeadersBin, _EC}} = hpack:encode(Headers, hpack:new_context()),

    HF = {#frame_header{length=byte_size(HeadersBin),
                        type=?HEADERS,
                        flags=?FLAG_END_HEADERS bor ?FLAG_END_STREAM,
                        stream_id=3},
          h2_frame_headers:new(HeadersBin)
         },
    http2c:send_unaltered_frames(Client, [HF]),

    timer:sleep(300),
    Resp1 = http2c:get_frames(Client, 3),
    Size1 = data_frame_size(Resp1),
    ?assertEqual(WindowSize, Size1),
    send_window_update(Client, 64),

    timer:sleep(200),
    Resp2 = http2c:get_frames(Client, 3),
    Size2 = data_frame_size(Resp2),
    ?assertEqual(WindowSize, Size2),

    send_window_update(Client, 64),
    timer:sleep(200),
    Resp3 = http2c:get_frames(Client, 3),
    Size3 = data_frame_size(Resp3),
    %% (68 * 2) - (64 * 2) = 8
    ?assertEqual(8, Size3).

data_frame_size(Frames) ->
    DataFrames = lists:filter(fun({#frame_header{type=?DATA}, _}) -> true;
                                 (_) -> false end, Frames),
    lists:foldl(fun({_FH, DataP}, Acc) ->
                        Data = h2_frame_data:data(DataP),
                        Acc + byte_size(Data) end,
                0, DataFrames).

send_window_update(Client, Size) ->
    http2c:send_unaltered_frames(Client,
                                 [{#frame_header{length=4,
                                                 type=?WINDOW_UPDATE,
                                                 stream_id=3},
                                   h2_frame_window_update:new(Size)
                                  }
                                 ]).
send_n_bytes(N) ->
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
    {ok, {HeadersBin, _EncodeContext}} = hpack:encode(Headers, hpack:new_context()),

    HeaderFrame = {#frame_header{
                      length=byte_size(HeadersBin),
                      type=?HEADERS,
                      flags=?FLAG_END_HEADERS,
                      stream_id=3
                     },
                   h2_frame_headers:new(HeadersBin)
                  },

    http2c:send_unaltered_frames(Client, [HeaderFrame]),
    %% If the server_connection_receive_window callback_mod worked,
    %% this headers frame should have increased the stream's recv
    %% window, but not the connections

    %% So now, send N bytes and we should get some desired error.
    Data = crypto:strong_rand_bytes(N),
    Frames = h2_frame_data:to_frames(3, Data, #settings{}),

    http2c:send_unaltered_frames(Client, Frames),

    Client.

%% TODO: Tests for sending data when send_*_window is too small
