-module(http2_frame_priority).

-include("http2.hrl").

-export([
         format/1,
         read_binary/2,
         read_priority/1,
         to_binary/1
        ]).

-behaviour(http2_frame).

-spec format(priority()) -> iodata().
format(Payload) ->
    io_lib:format("[Priority: ~p]", [Payload]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} |
    {error, term()}.
read_binary(Bin, #frame_header{stream_id=_Sid, length=5}) ->
    {Payload, Rem} = read_priority(Bin),
    {ok, Payload, Rem}.

-spec read_priority(binary()) -> {priority(), binary()}.
read_priority(Binary) ->
    <<Exclusive:1,StreamId:31,Weight:8,Rem/bits>> = Binary,
    Payload = #priority{
        exclusive = Exclusive,
        stream_id = StreamId,
        weight = Weight
    },
    {Payload, Rem}.

-spec to_binary(priority()) -> iodata().
to_binary(#priority{
             exclusive=E,
             stream_id=StreamId,
             weight=W
            }) ->
    <<E:1,StreamId:31,W:8>>.
