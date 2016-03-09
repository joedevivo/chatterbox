-module(http2_frame_data).

-include("http2.hrl").

-export([
         format/1,
         read_binary/2,
         to_frames/3,
         send/4,
         to_binary/1
        ]).

-behaviour(http2_frame).

-spec format(data()) -> iodata().
format(Payload) ->
    BinToShow = case size(Payload) > 7 of
        false ->
            Payload#data.data;
        true ->
            <<Start:8/binary,_/binary>> = Payload#data.data,
            Start
    end,
    io_lib:format("[Data: {data: ~p ...}]", [BinToShow]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()}.
read_binary(Bin, _H=#frame_header{length=0}) ->
    {ok, #data{data= <<>>}, Bin};
read_binary(Bin, H=#frame_header{length=L}) ->
    lager:info("read_binary L: ~p, actually: ~p", [L, byte_size(Bin)]),
    <<PayloadBin:L/binary,Rem/bits>> = Bin,
    Data = http2_padding:read_possibly_padded_payload(PayloadBin, H),
    {ok, #data{data=Data}, Rem}.

-spec to_frames(stream_id(), binary(), settings()) -> [frame()].
to_frames(StreamId, Data, S=#settings{max_frame_size=MFS}) ->
    L = byte_size(Data),
    case L >= MFS of
        false ->
            [{#frame_header{
                 length=L,
                 type=?DATA,
                 flags=?FLAG_END_STREAM,
                 stream_id=StreamId
                }, #data{data=Data}}];
            %%[[<<L:24,?DATA:8,?FLAG_END_STREAM:8,0:1,StreamId:31>>,Data]];
        true ->
            <<ToSend:MFS/binary,Rest/binary>> = Data,
            [{#frame_header{
                 length=MFS,
                 type=?DATA,
                 stream_id=StreamId
                },
              #data{data=ToSend}} | to_frames(StreamId, Rest, S)]
            %%[[<<MFS:24,?DATA:8,0:8,0:1,StreamId:31>>,ToSend] | to_frames(StreamId, Rest, S)]
    end.

%% TODO for POC response, Hardcoded
send({Transport, Socket}, StreamId, Data, Settings) ->
    Frames = to_frames(StreamId, Data, Settings),
    %%lager:info("send Frames: ~p", [Frames]),
    %%[ begin lager:info("F: ~p", [F]),  Transport:send(Socket, F) end || F <- Frames].
    [ Transport:send(Socket, F) || F <- Frames].

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
