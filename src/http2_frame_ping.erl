-module(http2_frame_ping).

-include("http2.hrl").

-behavior(http2_frame).

-export([read_binary/2]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary(<<Data:8/binary,Rem/bits>>, #frame_header{length=8}) ->
    Payload = #ping{
                 opaque_data = Data
                },
    {ok, Payload, Rem}.
