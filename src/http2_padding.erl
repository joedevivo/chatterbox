-module(http2_padding).

-export([is_padded/1, read_possibly_padded_payload/2]).

-include("http2.hrl").

-spec is_padded(frame_header()) -> boolean().
is_padded(#header{flags=Flags})
    when Flags band 16#8 == 1 ->
    true;
is_padded(_) ->
    false.

-spec read_possibly_padded_payload(socket() | binary(), frame_header()) -> {binary(), binary()}.
read_possibly_padded_payload(SockOrBin, Header) ->
    case is_padded(Header) of
        true ->
            read_padded_payload(SockOrBin, Header);
        false ->
            read_unpadded_payload(SockOrBin, Header)
    end.

-spec read_padded_payload(socket() | binary(), frame_header()) -> {binary(), binary()}.
read_padded_payload(<<Padding:8,Bytes/bits>> = Bin, #header{length=Length}) when is_binary(Bin) ->
    L = Length - Padding,
    <<Data:L/binary,_:Padding/binary,Rem/bits>> = Bytes,
    {Data, Rem};
read_padded_payload({Transport, Socket}, Header = #header{length=Length}) ->
    {ok, Bytes} = Transport:recv(Socket,Length),
    read_padded_payload(Bytes, Header).

-spec read_unpadded_payload(socket() | binary(), frame_header()) -> binary().
read_unpadded_payload(Bin, #header{length=Length}) when is_binary(Bin) ->
    <<Data:Length/binary,Rem/bits>> = Bin,
    {Data, Rem};
read_unpadded_payload({Transport, Socket}, #header{length=Length}) ->
    {ok, Data} = Transport:recv(Socket, Length),
    {Data, <<>>}.
