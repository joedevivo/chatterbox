-module(h2_padding).
-include("http2.hrl").

-export([
         is_padded/1,
         read_possibly_padded_payload/2
        ]).

-spec is_padded(h2_frame:header()) -> boolean().
is_padded(#frame_header{flags=Flags})
    when ?IS_FLAG(Flags, ?FLAG_PADDED) ->
    true;
is_padded(_) ->
    false.

-spec read_possibly_padded_payload(binary(),
                                   h2_frame:header())
                                  -> binary() | {error, error_code()}.
read_possibly_padded_payload(Bin, H=#frame_header{flags=F})
  when ?IS_FLAG(F, ?FLAG_PADDED) ->
    read_padded_payload(Bin, H);
read_possibly_padded_payload(Bin, Header) ->
    read_unpadded_payload(Bin, Header).

-spec read_padded_payload(binary(), h2_frame:header())
                         -> binary() | {error, error_code()}.
read_padded_payload(<<Padding:8,Bytes/bits>>,
                    #frame_header{length=Length}) ->
    L = Length - Padding - 1, % Exclude Pad length field (1 byte)
    case L >= 0 of
        true ->
            <<Data:L/binary,_:Padding/binary>> = Bytes,
            Data;
        false ->
            {error, ?PROTOCOL_ERROR}
    end.

-spec read_unpadded_payload(binary(), h2_frame:header())
                           -> binary().
read_unpadded_payload(Data, _H) ->
    Data.
