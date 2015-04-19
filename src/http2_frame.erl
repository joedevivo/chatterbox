-module(http2_frame).

-include("http2.hrl").

-export([
         read/1,
         from_binary/1
]).

%% Each frame type should be able to be read off a binary stream. If
%% the header is good, then it'll know how many more bytes to take off
%% the stream for the payload. If there are more bytes left over, it's
%% the next header, so we should return a tuple that contains the
%% remainder as well.
-callback read_binary(Bin::binary(),
                      Header::frame_header()) ->
    {ok, payload(), Remainder::binary()} | {error, term()}.

%% TODO: some kind of callback for sending frames
%-callback send(port(), payload()) -> ok | {error, term()}.

-spec read(socket()) -> {frame_header(), payload()}.
read(Socket) ->
    {H, <<>>} = read_header(Socket),
    lager:debug("Frame Type: ~p", [H#frame_header.type]),
    {ok, Payload, <<>>} = read_payload(Socket, H),
    {H, Payload}.

-spec from_binary(binary()) -> [{frame_header(), payload()}].
from_binary(Bin) ->
    from_binary(Bin, []).

from_binary(<<>>, Acc) ->
    Acc;
from_binary(Bin, Acc) ->
    {Header, PayloadBin} = read_binary_frame_header(Bin),
    {ok, Payload, Rem} = read_binary_payload(PayloadBin, Header),
    from_binary(Rem, [{Header, Payload}|Acc]).


-spec read_header(socket()) -> {frame_header(), binary()}.
read_header({Transport, Socket}) ->
    lager:debug("reading http2 header"),
    {ok, HeaderBytes} = Transport:recv(Socket, 9),
    read_binary_frame_header(HeaderBytes).

-spec read_binary_frame_header(binary()) -> {frame_header(), binary()}.
read_binary_frame_header(<<Length:24,Type:8,Flags:8,R:1,StreamId:31,Rem/bits>>) ->
    lager:debug("Frame Header: L:~p, T:~p, F:~p, R:~p, StrId:~p", [Length, Type, Flags, R, StreamId]),
    {#frame_header{
        length = Length,
        type = Type,
        flags = Flags,
        stream_id = StreamId
    }, Rem}.


-spec read_payload(socket(), frame_header()) ->
    {ok, payload(), <<>>} | {error, term()}.
read_payload(_, #frame_header{length=0}) ->
    {ok, <<>>, <<>>};
read_payload({Transport, Socket}, Header=#frame_header{length=L}) ->
    {ok, DataBin} = Transport:recv(Socket, L),
    read_binary_payload(DataBin, Header).

-spec read_binary_payload(binary(), frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary_payload(Bin, Header = #frame_header{type=?DATA}) ->
    http2_frame_data:read_binary(Bin, Header);
read_binary_payload(Socket, Header = #frame_header{type=?HEADERS}) ->
    http2_frame_headers:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?PRIORITY}) ->
    http2_frame_priority:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?RST_STREAM}) ->
    http2_frame_rst_stream:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?SETTINGS}) ->
    http2_frame_settings:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?PUSH_PROMISE}) ->
    http2_frame_push_promise:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?PING}) ->
    http2_frame_ping:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?GOAWAY}) ->
    http2_frame_goaway:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?WINDOW_UPDATE}) ->
    http2_frame_window_update:read_binary(Socket, Header);
read_binary_payload(Socket, Header = #frame_header{type=?CONTINUATION}) ->
    http2_frame_continuation:read_binary(Socket, Header).
