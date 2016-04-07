-module(http2_frame_headers).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
    format/1,
    from_frames/1,
    read_binary/2,
    to_frames/5,
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

-spec to_frames(StreamId      :: stream_id(),
                Headers       :: hpack:headers(),
                EncodeContext :: hpack:context(),
                MaxFrameSize  :: pos_integer(),
                EndStream     :: boolean()) ->
                       {[frame()], hpack:context()}.
to_frames(StreamId, Headers, EncodeContext, MaxFrameSize, EndStream) ->
    {ok, {HeadersBin, NewContext}} = hpack:encode(Headers, EncodeContext),

    %% Break HeadersBin into chunks
    Chunks = split(HeadersBin, MaxFrameSize),

    Frames = build_frames(StreamId, Chunks, EndStream),

    {Frames, NewContext}.

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

-spec split(Binary::binary(),
            MaxFrameSize::pos_integer()) ->
                   [binary()].
split(Binary, MaxFrameSize) ->
    split(Binary, MaxFrameSize, []).

-spec split(Binary::binary(),
            MaxFrameSize::pos_integer(),
            [binary()]) ->
                   [binary()].
split(Binary, MaxFrameSize, Acc)
  when byte_size(Binary) =< MaxFrameSize ->
    lists:reverse([Binary|Acc]);
split(Binary, MaxFrameSize, Acc) ->
    <<NextFrame:MaxFrameSize/binary,Remaining/binary>> = Binary,
    split(Remaining, MaxFrameSize, [NextFrame|Acc]).

%% Now build frames.
%% The first will be a HEADERS frame, followed by CONTINUATION
%% If EndStream, that flag needs to be set on the first frame
%% ?FLAG_END_HEADERS needs to be set on the last.
%% If there's only one, it needs to be set on both.
-spec build_frames(StreamId :: stream_id(),
                   Chunks::[binary()],
                   EndStream::boolean()) ->
                          [frame()].
build_frames(StreamId, [FirstChunk|Rest], EndStream) ->
    Flag = case EndStream of
               true ->
                   ?FLAG_END_STREAM;
               false ->
                   0
           end,
    HeadersFrame =
        { #frame_header{
             type=?HEADERS,
             flags=Flag,
             length=byte_size(FirstChunk),
             stream_id=StreamId},
          #headers{
             block_fragment=FirstChunk}},
    [{LastFrameHeader, LastFrameBody}|Frames] =
        build_frames_(StreamId, Rest, [HeadersFrame]),
    NewLastFrame = {
      LastFrameHeader#frame_header{
        flags=LastFrameHeader#frame_header.flags bor ?FLAG_END_HEADERS
       },
      LastFrameBody},

    lists:reverse([NewLastFrame|Frames]).

-spec build_frames_(StreamId::stream_id(),
                    Chunks::[binary()],
                    Acc::[frame()])->
                           [frame()].
build_frames_(_StreamId, [], Acc) ->
    Acc;
build_frames_(StreamId, [NextChunk|Rest], Acc) ->
    NextFrame = {
      #frame_header{
         stream_id=StreamId,
         type=?CONTINUATION,
         flags=0,
         length=byte_size(NextChunk)
        },
      #continuation{
         block_fragment=NextChunk
        }
     },
    build_frames_(StreamId, Rest, [NextFrame|Acc]).
