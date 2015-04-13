-module(http2_frame_data).

-export([read_payload/2, send/3]).

-include("http2.hrl").

-behaviour(http2_frame).

-spec read_payload(Socket :: socket(),
                   Header::header()) ->
    {ok, payload()} |
    {error, term()}.
read_payload(_Socket, #header{stream_id=0}) ->
    {error, 'PROTOCOL_ERROR'};
read_payload(Socket, Header=#header{flags=Flags}) ->
    _ = Flags band 16#1,
    Data = http2_padding:read_possibly_padded_payload(Socket, Header),
    {ok, #data{data=Data}, <<>>}.

%% TODO for POC response, Hardcoded
send({Transport, Socket}, StreamId, Data) ->
    L = byte_size(Data),
    Transport:send(Socket, [<<L:24,?DATA:8,?FLAG_END_STREAM:8,0:1,StreamId:31>>,Data]).
