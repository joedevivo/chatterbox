-module(settings_handshake_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [times_out_on_no_ack_of_server_settings,
     protocol_error_on_never_send_client_settings].

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.


%% This test does not use the http2c client because it needs to
%% circumvent a behavior that the http2c takes for granted.

%% This is an optional behavior as per section 6.5 of the HTTP/2 RFC
%% 7540
%% If the sender of a SETTINGS frame does not receive an
%% acknowledgement within a reasonable amount of time, it MAY issue a
%% connection error (Section 5.4.1) of type SETTINGS_TIMEOUT.
times_out_on_no_ack_of_server_settings(Config) ->
    chatterbox_test_buddy:start([{ssl, true}|Config]),

    {ok, Port} = application:get_env(chatterbox, port),
    ClientOptions = [
               binary,
               {packet, raw},
               {active, false}
              ],
    {ok, SSLOptions} = application:get_env(chatterbox, ssl_options),
    Options =  ClientOptions ++ SSLOptions ++ [{client_preferred_next_protocols, {client, [<<"h2">>]}}],

    Transport = ssl,

    {ok, Socket} = Transport:connect("localhost", Port, Options),

    Transport:send(Socket, <<?PREFACE>>),

    %% Now send client settings so the problem becomes that we do not ack
    ClientSettings = #settings{},
    Bin = http2_frame_settings:send(#settings{}, ClientSettings),
    Transport:send(Socket, Bin),

    %% Settings Frame

    %% Two receives. one for server settings, and one for client settings ack
    {ok, _Settings1 = <<0,0,L1,4,_,0,0,0,0>>} = Transport:recv(Socket, 9, 1000),
    case L1 of
        0 ->
            ok;
        _ ->
            {ok, _DontCare} = Transport:recv(Socket, L1, 1000)
    end,
    {ok, _Settings2 = <<0,0,0,4,_,0,0,0,0>>} = Transport:recv(Socket, 9, 1000),

    %% Since we never send our ack, we should get a settings timeout in 5000ms
    ct:pal("waiting for timeout, should arrive in 5000ms"),
    {ok, GoAwayBin} = Transport:recv(Socket, 0, 6000),

    ct:pal("GoAwayBin: ~p", [GoAwayBin]),
    [{FH, GoAway}] = http2_frame:from_binary(GoAwayBin),
    ct:pal("Type: ~p", [FH#frame_header.type]),
    ?GOAWAY = FH#frame_header.type,
    ?SETTINGS_TIMEOUT = GoAway#goaway.error_code,
    ok.

protocol_error_on_never_send_client_settings(Config) ->
    chatterbox_test_buddy:start([{ssl, true}|Config]),

    {ok, Port} = application:get_env(chatterbox, port),
    ClientOptions = [
               binary,
               {packet, raw},
               {active, false}
              ],
    {ok, SSLOptions} = application:get_env(chatterbox, ssl_options),
    Options =  ClientOptions ++ SSLOptions ++ [{client_preferred_next_protocols, {client, [<<"h2">>]}}],

    Transport = ssl,

    {ok, Socket} = Transport:connect("localhost", Port, Options),

    Transport:send(Socket, <<?PREFACE>>),

    %% This is the settings frame. Do not ACK
    {ok, _Settings1 = <<0,0,L,4,0,0,0,0,0>>} = Transport:recv(Socket, 9, 1000),
    case L of
        0 ->
            ok;
        _ ->
            {ok, _DontCare} = Transport:recv(Socket, L, 1000)
    end,

    ct:pal("waiting for timeout, should arrive in 5000ms"),
    {ok, GoAwayBin} = Transport:recv(Socket, 0, 6000),

    ct:pal("GoAwayBin: ~p", [GoAwayBin]),
    [{FH, GoAway}] = http2_frame:from_binary(GoAwayBin),
    ct:pal("Type: ~p", [FH#frame_header.type]),
    ?GOAWAY = FH#frame_header.type,
    ct:pal("Error code: ~p", [GoAway#goaway.error_code]),
    ?SETTINGS_TIMEOUT = GoAway#goaway.error_code,
    ok.

default_setting_honored_before_ack(_Config) ->
    %% configure settings for smaller frame size, 2048

    %% send frame with 2048 < size < 16384

    %% send ack

    %% send frame size > 2048, now should fail
    ok.
