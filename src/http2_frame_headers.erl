-module(http2_frame_headers).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
    format/1,
    from_frames/1,
    read_binary/2,
    to_frame/3,
    send/4,
    to_binary/1
  ]).

-spec format(headers()) -> iodata().
format(Payload) ->
    io_lib:format("[Headers: ~p]", [Payload]).

-spec read_binary(binary(), frame_header()) ->
                         {ok, payload(), binary()}
                       | {error, error_code()}.
read_binary(Bin, H = #frame_header{length=L}) ->
    <<PayloadBin:L/binary,Rem/bits>> = Bin,
    case http2_padding:read_possibly_padded_payload(PayloadBin, H) of
        {error, Code} ->
            {error, Code};
        Data ->
            {Priority, HeaderFragment} =
                case is_priority(H) of
                    true ->
                        http2_frame_priority:read_priority(Data);
                    false ->
                        {undefined, Data}
                end,

            Payload = #headers{
                         priority=Priority,
                         block_fragment=HeaderFragment
                        },
            {ok, Payload, Rem}
    end.

is_priority(#frame_header{flags=F}) when ?IS_FLAG(F, ?FLAG_PRIORITY) ->
    true;
is_priority(_) ->
    false.

-spec to_frame(pos_integer(), hpack:headers(), hpack:context()) ->
                      {{frame_header(), headers()}, hpack:context()}.
%% Maybe break this up into continuations like the data frame
to_frame(StreamId, Headers, EncodeContext) ->
    {ok, {HeadersToSend, NewContext}} = hpack:encode(Headers, EncodeContext),
    L = byte_size(HeadersToSend),
    {{#frame_header{
         length=L,
         type=?HEADERS,
         flags=?FLAG_END_HEADERS,
         stream_id=StreamId
        },
      #headers{
         block_fragment=HeadersToSend
        }},
    NewContext}.

send({Transport, Socket}, StreamId, Headers, EncodeContext) ->
    {Frame, NewContext} = to_frame(StreamId, Headers, EncodeContext),
    Bytes = http2_frame:to_binary(Frame),
    Transport:send(Socket, Bytes),
    NewContext.

-spec to_binary(headers()) -> iodata().
to_binary(#headers{
             priority=P,
             block_fragment=BF
            }) ->
    case P of
        undefined ->
            BF;
        _ ->
            [http2_frame_priority:to_binary(P), BF]
    end.

-spec from_frames([frame()], binary()) -> binary().
from_frames([{#frame_header{type=?HEADERS},#headers{block_fragment=BF}}|Continuations])->
    from_frames(Continuations, BF);
from_frames([{#frame_header{type=?PUSH_PROMISE},#push_promise{block_fragment=BF}}|Continuations])->
    from_frames(Continuations, BF).

from_frames([], Acc) ->
    Acc;
from_frames([{#frame_header{type=?CONTINUATION},#continuation{block_fragment=BF}}|Continuations], Acc) ->
    from_frames(Continuations, <<Acc/binary,BF/binary>>).
