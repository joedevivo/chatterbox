-module(h2_frame_continuation).
-include("http2.hrl").
-behaviour(h2_frame).

-export(
   [
    block_fragment/1,
    format/1,
    new/1,
    read_binary/2,
    to_binary/1
   ]).

-record(continuation, {
          block_fragment :: binary()
}).
-type payload() :: #continuation{}.
-type frame() :: {h2_frame:header(), payload()}.
-export_type([payload/0, frame/0]).

-spec block_fragment(payload()) -> binary().
block_fragment(#continuation{block_fragment=BF}) ->
    BF.

-spec new(binary()) -> payload().
new(Bin) ->
    #continuation{
       block_fragment=Bin
      }.
-spec read_binary(binary(), h2_frame:header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(_,
            #frame_header{
               stream_id=0
               }) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
read_binary(Bin, #frame_header{length=Length}) ->
    <<Data:Length/binary,Rem/bits>> = Bin,
    Payload = #continuation{
                 block_fragment=Data
                },
    {ok, Payload, Rem}.

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[Continuation: ~p ]", [Payload]).

-spec to_binary(payload()) -> iodata().
to_binary(#continuation{block_fragment=BF}) ->
    BF.
