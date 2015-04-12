-module(http2_frame_settings).

-define(SETTINGS_HEADER_TABLE_SIZE,         <<16#1>>).
-define(SETTINGS_ENABLE_PUSH,               <<16#2>>).
-define(SETTINGS_MAX_CONCURRENT_STREAMS,    <<16#3>>).
-define(SETTINGS_INITIAL_WINDOW_SIZE,       <<16#4>>).
-define(SETTINGS_MAX_FRAME_SIZE,            <<16#5>>).
-define(SETTINGS_MAX_HEADER_LIST_SIZE,      <<16#6>>).


-include("http2.hrl").

-behaviour(http2_frame).

-export([read_payload/2, send/2, ack/1]).

read_payload(_Socket, _Header = #header{length=0}) ->
    {ok, <<>>};
read_payload({Transport, Socket}, _Header = #header{length=Length}) ->
    {ok, Payload} = Transport:recv(Socket, Length),
    Settings = parse_settings(Payload),
    lager:debug("Settings: ~p", [Settings]),
    {ok, Settings}.

-spec parse_settings(binary()) -> settings().
parse_settings(Bin) ->
    parse_settings(Bin, #settings{}).

-spec parse_settings(binary(), settings()) -> settings().
parse_settings(<<0,3,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, S#settings{max_concurrent_streams=binary:decode_unsigned(Val)});
parse_settings(<<0,4,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, S#settings{initial_window_size=binary:decode_unsigned(Val)});
parse_settings(<<>>, Settings) ->
    Settings.

-spec send(socket(), settings()) -> ok | {error, term()}.
send({Transport, Socket}, _Settings) ->
    %% TODO: hard coded settings frame. needs to be figured out from _Settings
    %% Also needs to be compared to ?DEFAULT_SETTINGS
    %% and only send the ones that are different
    %% or maybe it's the fsm's current settings.
    %% figure out later
    Header = <<12:24,?SETTINGS:8,16#0:8,0:1,0:31>>,

    Payload = <<3:16,
                100:32,
                4:16,
                65535:32>>,
    Frame = [Header, Payload],
    lager:debug("sending settings ~p", [Frame]),
    Transport:send(Socket, Frame).

-spec ack(socket()) -> ok | {error, term()}.
ack({Transport,Socket}) ->
    Transport:send(Socket, <<0:24,4:8,1:8,0:1,0:31>>).
