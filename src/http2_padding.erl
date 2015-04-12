-module(http2_padding).

-export([is_padded/1, read_possibly_padded_payload/2]).

-include("http2.hrl").

-spec is_padded(frame_header()) -> boolean().
is_padded(#header{flags=Flags})
    when Flags band 16#8 == 1 ->
    true;
is_padded(_) ->
    false.

read_possibly_padded_payload(Sock, Header) ->
    case is_padded(Header) of
        true ->
            read_padded_payload(Sock, Header);
        false ->
            read_unpadded_payload(Sock, Header)
    end.

read_padded_payload({Transport, Socket}, #header{length=Length}) ->
    {ok, <<Padding>>} = Transport:recv(Socket,1),
    Data = Transport:recv(Socket, Length-Padding),
    _ = Transport:recv(Socket, Padding),
    Data.

read_unpadded_payload({Transport, Socket}, #header{length=Length}) ->
    {ok, Data} = Transport:recv(Socket, Length),
    Data.
