-module(http2_frame).

-include("http2.hrl").

-export([read/1]).

-callback read_payload(Socket :: socket(),
                       Header::header()) ->
    {ok, payload()} |
    {error, term()}.

%-callback send(port(), payload()) -> ok | {error, term()}.

-spec read(socket()) -> {header(), payload()}.
read(Socket) ->
    Header = read_header(Socket),
    lager:debug("Frame Type: ~p", [Header#header.type]),
    {ok, Payload} = read_payload(Socket, Header),
    {Header, Payload}.

-spec read_header(socket()) -> header().
read_header({Transport, Socket}) ->
    lager:debug("reading http2 header"),
    {ok, <<Length:24,Type:8,Flags:8,R:1,StreamId:31>>} = Transport:recv(Socket, 9),
    lager:debug("Length: ~p", [Length]),
    lager:debug("Type: ~p", [Type]),
    lager:debug("Flags: ~p", [Flags]),
    lager:debug("R: ~p", [R]),
    lager:debug("StreamId: ~p", [StreamId]),

    #header{
        length = Length,
        type = Type,
        flags = Flags,
        stream_id = StreamId
    }.

-spec read_payload(port(), header()) ->
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
