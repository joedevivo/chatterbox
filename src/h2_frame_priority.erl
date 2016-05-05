-module(h2_frame_priority).
-include("http2.hrl").
-behaviour(h2_frame).

-export(
   [
    format/1,
    new/3,
    stream_id/1,
    read_binary/2,
    read_priority/1,
    to_binary/1
   ]).

-record(priority, {
    exclusive = 0 :: 0 | 1,
    stream_id = 0 :: stream_id(),
    weight = 0 :: non_neg_integer()
  }).
-type payload() :: #priority{}.
-type frame() :: {h2_frame:header(), payload()}.
-export_type([payload/0, frame/0]).

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[Priority: ~p]", [Payload]).

-spec new(0|1, stream_id(), non_neg_integer()) -> payload().
new(Exclusive, StreamId, Weight) ->
    #priority{
       exclusive=Exclusive,
       stream_id=StreamId,
       weight=Weight
      }.

-spec read_binary(binary(), h2_frame:header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(_,
            #frame_header{
               stream_id=0
              }) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
read_binary(_,
           #frame_header{
             length=L
             })
  when L =/= 5 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
read_binary(Bin,
            #frame_header{
               length=5
              }=H) ->
    {Payload, Rem} = read_priority(Bin),
    PriorityStream = Payload#priority.stream_id,
    case H#frame_header.stream_id of
        0 ->
            {error, 0, ?PROTOCOL_ERROR, Rem};
        PriorityStream ->
            {error, H#frame_header.stream_id, ?PROTOCOL_ERROR, Rem};
        _ ->
            {ok, Payload, Rem}
    end.

-spec read_priority(binary()) -> {payload(), binary()}.
read_priority(Binary) ->
    <<Exclusive:1,StreamId:31,Weight:8,Rem/bits>> = Binary,
    Payload = #priority{
        exclusive = Exclusive,
        stream_id = StreamId,
        weight = Weight
    },
    {Payload, Rem}.

-spec stream_id(payload()) -> stream_id().
stream_id(#priority{stream_id=S}) ->
    S.

-spec to_binary(payload()) -> iodata().
to_binary(#priority{
             exclusive=E,
             stream_id=StreamId,
             weight=W
            }) ->
    <<E:1,StreamId:31,W:8>>.
