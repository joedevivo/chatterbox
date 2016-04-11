-module(http2_frame_ping).

-include("http2.hrl").

-behaviour(http2_frame).

-export(
   [
    format/1,
    read_binary/2,
    to_binary/1,
    ack/1,
    new/1
    ]).

-record(ping, {
          opaque_data :: binary()
}).
-type payload() :: #ping{}.
-export_type([payload/0]).

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[Ping: ~p]", [Payload]).

-spec new(binary()) -> payload().
new(Bin) ->
    #ping{opaque_data=Bin}.

-spec read_binary(binary(), frame_header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(<<Data:8/binary,Rem/bits>>, #frame_header{length=8}) ->
    Payload = #ping{
                 opaque_data = Data
                },
    {ok, Payload, Rem};
read_binary(_, _) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>}.

-spec to_binary(payload()) -> iodata().
to_binary(#ping{opaque_data=D}) ->
    D.

-spec ack(payload()) -> {frame_header(), payload()}.
ack(Ping) ->
    {#frame_header{
        length = 8,
        type = ?PING,
        flags = ?FLAG_ACK,
        stream_id = 0
       }, Ping}.
