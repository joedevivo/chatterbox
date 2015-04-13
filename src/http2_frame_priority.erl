-module(http2_frame_priority).

-export([
         read_payload/2,
         read_priority/1
        ]).

-include("http2.hrl").

-behaviour(http2_frame).

-spec read_payload(Socket :: socket(),
                   Header::header()) ->
    {ok, payload()} |
    {error, term()}.
read_payload({Transport, Socket}, #header{stream_id=0,length=5}) ->
    {ok, Bin} = Transport:recv(Socket, 5),
    {Payload, <<>>} = read_priority(Bin),
    {ok, Payload, <<>>}.

-spec read_priority(binary()) -> {priority(), binary()}.
read_priority(Binary) ->
    <<Exclusive:1,StreamId:31,Weight:8,Extra/bits>> = Binary,
    Payload = #priority{
        exclusive = Exclusive,
        stream_id = StreamId,
        weight = Weight
    },
    {Payload, Extra}.
