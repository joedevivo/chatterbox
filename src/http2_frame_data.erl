-module(http2_frame_data).

-include("http2.hrl").

-export([
         format/1,
         read_binary/2,
         to_frame/2,
         send/3,
         to_binary/1
        ]).

-behaviour(http2_frame).

-spec format(data()) -> iodata().
format(Payload) ->
    io_lib:format("[Data: ~p]", [Payload]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} |
    {error, term()}.
read_binary(_, #frame_header{stream_id=0}) ->
    {error, 'PROTOCOL_ERROR'};
read_binary(Bin, _H=#frame_header{length=0}) ->
    {ok, #data{data= <<>>}, Bin};
read_binary(Bin, H=#frame_header{length=L}) ->
    lager:info("read_binary L: ~p", [L]),
    <<PayloadBin:L/binary,Rem/bits>> = Bin,
    Data = http2_padding:read_possibly_padded_payload(PayloadBin, H),
    {ok, #data{data=Data}, Rem}.

to_frame(StreamId, Data) ->
    L = byte_size(Data),
    case L >= 16384 of
        false ->
            [[<<L:24,?DATA:8,?FLAG_END_STREAM:8,0:1,StreamId:31>>,Data]];
        true ->
            <<ToSend:16384/binary,Rest/binary>> = Data,
            [[<<16384:24,?DATA:8,0:8,0:1,StreamId:31>>,ToSend] | to_frame(StreamId, Rest)]
    end.

%% TODO for POC response, Hardcoded
send({Transport, Socket}, StreamId, Data) ->
    Frames = to_frame(StreamId, Data),
    lager:info("send Frames: ~p", [Frames]),
    [ begin lager:info("F: ~p", [F]),  Transport:send(Socket, F) end || F <- Frames].

-spec to_binary(data()) -> iodata().
to_binary(#data{data=D}) ->
    D.

%    L = byte_size(Data),
%    case L >= 16384 of
%        false ->
%            Transport:send(Socket, [<<L:24,?DATA:8,?FLAG_END_STREAM:8,0:1,StreamId:31>>,Data]);
%        true ->
%            <<ToSend:16384/binary,Rest/binary>> = Data,
%            Transport:send(Socket, [<<16384:24,?DATA:8,0:8,0:1,StreamId:31>>,ToSend]),
%            send({Transport,Socket}, StreamId, Rest)
%    end.
