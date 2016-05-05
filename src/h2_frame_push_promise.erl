-module(h2_frame_push_promise).
-include("http2.hrl").
-behaviour(h2_frame).

-export(
   [
    block_fragment/1,
    format/1,
    new/2,
    promised_stream_id/1,
    read_binary/2,
    to_binary/1,
    to_frame/4
    ]).

-record(push_promise, {
          promised_stream_id :: stream_id(),
          block_fragment :: binary()
}).
-type payload() :: #push_promise{}.
-type frame() :: {h2_frame:header(), payload()}.
-export_type([payload/0, frame/0]).

-spec block_fragment(payload()) -> binary().
block_fragment(#push_promise{block_fragment=BF}) ->
    BF.

-spec promised_stream_id(payload()) -> stream_id().
promised_stream_id(#push_promise{promised_stream_id=PSID}) ->
    PSID.

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[Headers: ~p]", [Payload]).

-spec new(stream_id(), binary()) -> payload().
new(StreamId, Bin) ->
    #push_promise{
       promised_stream_id=StreamId,
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
read_binary(Bin, H=#frame_header{length=L}) ->
    <<PayloadBin:L/binary,Rem/binary>> = Bin,
    Data = h2_padding:read_possibly_padded_payload(PayloadBin, H),
    <<_R:1,Stream:31,BlockFragment/bits>> = Data,
    Payload = #push_promise{
                 promised_stream_id=Stream,
                 block_fragment=BlockFragment
                },
    {ok, Payload, Rem}.

-spec to_frame(pos_integer(), pos_integer(), hpack:headers(), hpack:context()) ->
                      {{h2_frame:header(), payload()}, hpack:context()}.
%% Maybe break this up into continuations like the data frame
to_frame(StreamId, PStreamId, Headers, EncodeContext) ->
    {ok, {HeadersToSend, NewContext}} = hpack:encode(Headers, EncodeContext),
    L = byte_size(HeadersToSend),
    {{#frame_header{
         length=L,
         type=?PUSH_PROMISE,
         flags=?FLAG_END_HEADERS,
         stream_id=StreamId
        },
      #push_promise{
         promised_stream_id=PStreamId,
         block_fragment=HeadersToSend
        }},
    NewContext}.

-spec to_binary(payload()) -> iodata().
to_binary(#push_promise{
             promised_stream_id=PSID,
             block_fragment=BF
            }) ->
    %% TODO: allow for padding as per HTTP/2 SPEC
    <<0:1,PSID:31,BF/binary>>.
