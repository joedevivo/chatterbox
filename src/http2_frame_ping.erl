-module(http2_frame_ping).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
    format/1,
    read_binary/2,
    to_binary/1,
    ack/1
    ]).

-spec format(ping()) -> iodata().
format(Payload) ->
    io_lib:format("[Ping: ~p]", [Payload]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary(<<Data:8/binary,Rem/bits>>, #frame_header{length=8}) ->
    Payload = #ping{
                 opaque_data = Data
                },
    {ok, Payload, Rem}.

-spec to_binary(ping()) -> iodata().
to_binary(#ping{opaque_data=D}) ->
    D.

-spec ack(ping()) -> {frame_header(), ping()}.
ack(Ping) ->
    {#frame_header{
        length = 8,
        type = ?PING,
        flags = ?FLAG_ACK,
        stream_id = 0
       }, Ping}.
