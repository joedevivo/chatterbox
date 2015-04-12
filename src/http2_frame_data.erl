-module(http2_frame_data).

-export([read_payload/2]).

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
    {ok, #data{data=Data}}.


%-spec send(port(), payload()) -> ok | {error, term()}.
%send(Socket, Bin) when is_binary(Bin) ->
%    L = length(Bin),
%    H = <<L:24,?DATA:8,1:8,0:1
%

