-module(http2_frame_settings).

-include("http2.hrl").

-behaviour(http2_frame).

-export([read_payload/2, ack/2, ack/1]).

read_payload(Socket, _Header = #header{length=0}) ->
    none;
read_payload(Socket, _Header = #header{length=Length}) ->
    {ok, Payload} = gen_tcp:recv(Socket, Length),
    Settings = parse_settings(Payload),
    lager:debug("Settings: ~p", [Settings]),
    {ok, Settings}.

-spec parse_settings(binary()) -> settings().
parse_settings(Bin) ->
    parse_settings(Bin, #settings{}).

-spec parse_settings(binary(), port()) -> settings().
parse_settings(<<0,3,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, S#settings{max_concurrent_streams=binary:decode_unsigned(Val)});
parse_settings(<<0,4,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, S#settings{initial_window_size=binary:decode_unsigned(Val)});
parse_settings(<<>>, Settings) ->
    Settings.

-spec ack(port(), settings()) -> port().
ack(Socket, _Settings) ->

    Header = <<12:24,?SETTINGS:8,16#0:8,0:1,0:31>>,

    Payload = <<3:16,
                100:32,
                4:16,
                65535:32>>,
    Frame = [Header, Payload],
    lager:debug("sending ack ~p", [Frame]),
    gen_tcp:send(Socket, Frame),
    Socket.

ack(Socket) ->
    gen_tcp:send(Socket, <<0:24,4:8,1:8,0:1,0:31>>).
