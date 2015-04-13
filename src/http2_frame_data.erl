-module(http2_frame_data).

-include("http2.hrl").

-export([
         read_binary/2,
         send/3
        ]).

-behaviour(http2_frame).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} |
    {error, term()}.
read_binary(_, #frame_header{stream_id=0}) ->
    {error, 'PROTOCOL_ERROR'};
read_binary(Bin, H=#frame_header{length=L}) ->
    <<PayloadBin:L/binary,Rem/bits>> = Bin,
    Data = http2_padding:read_possibly_padded_payload(PayloadBin, H),
    {ok, #data{data=Data}, Rem}.

%% TODO for POC response, Hardcoded
send({Transport, Socket}, StreamId, Data) ->
    L = byte_size(Data),
    Transport:send(Socket, [<<L:24,?DATA:8,?FLAG_END_STREAM:8,0:1,StreamId:31>>,Data]).
