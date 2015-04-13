-module(http2_frame).

-include("http2.hrl").

-export([read/1, from_binary/1]).

-callback read_payload(Socket :: socket() | binary(),
                       Header::header()) ->
    {ok, payload(), Remainder :: binary()} |
    {error, term()}.

%-callback send(port(), payload()) -> ok | {error, term()}.

-spec read(socket()) -> {header(), payload()}.
read(Socket) ->
    {Header, <<>>} = read_header(Socket),
    lager:debug("Frame Type: ~p", [Header#header.type]),
    {ok, Payload, <<>>} = read_payload(Socket, Header),
    {Header, Payload}.

-spec from_binary(binary()) -> {frame_header(), payload()}.
from_binary(Bin) ->
    from_binary(Bin, []).

from_binary(<<>>, Acc) ->
    Acc;
from_binary(Bin, Acc) ->
    {Header, PayloadBin} = read_header(Bin),
    {ok, Payload, Rem} = read_payload(PayloadBin, Header),
    from_binary(Rem, [{Header, Payload}|Acc]).


-spec read_header(socket()) -> {header(), binary()}.
read_header({Transport, Socket}) when is_port(Socket) ->
    lager:debug("reading http2 header"),
    {ok, HeaderBytes} = Transport:recv(Socket, 9),
    read_header(HeaderBytes);
read_header(<<Length:24,Type:8,Flags:8,R:1,StreamId:31,Rem/bits>>) ->
    lager:debug("Length: ~p", [Length]),
    lager:debug("Type: ~p", [Type]),
    lager:debug("Flags: ~p", [Flags]),
    lager:debug("R: ~p", [R]),
    lager:debug("StreamId: ~p", [StreamId]),

    {#header{
        length = Length,
        type = Type,
        flags = Flags,
        stream_id = StreamId
    }, Rem}.

-spec read_payload(port() | binary(), header()) ->
    {ok, payload()} | {error, term()}.
read_payload(Socket, Header = #header{type=?DATA}) ->
    http2_frame_data:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?HEADERS}) ->
    http2_frame_headers:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?PRIORITY}) ->
    http2_frame_priority:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?RST_STREAM}) ->
    http2_frame_rst_stream:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?SETTINGS}) ->
    http2_frame_settings:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?PUSH_PROMISE}) ->
    http2_frame_push_promise:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?PING}) ->
    http2_frame_ping:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?GOAWAY}) ->
    http2_frame_goaway:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?WINDOW_UPDATE}) ->
    http2_frame_window_update:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?CONTINUATION}) ->
    http2_frame_continuation:read_payload(Socket, Header);
read_payload(_Socket, #header{type=T}) ->
    lager:error("Unknown Header Type: ~p", [T]),
    {error, "bad header type"}.
