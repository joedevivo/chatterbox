-module(http2_frame).

-include("http2.hrl").

-export([read/1]).

-callback read_payload(Socket :: port(),
                       Header::header()) ->
    {ok, payload()} |
    {error, term()}.

-spec read(port()) -> {header(), payload()}.
read(Socket) ->
    Header = read_header(Socket),
    Payload = read_payload(Socket, Header),
    {Header, Payload}.

-spec read_header(port()) -> header().
read_header(Socket) ->
    lager:debug("reading http2 header"),
    {ok, <<Length:24,Type:8,Flags:8,R:1,StreamId:31>>} = gen_tcp:recv(Socket, 9),
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
read_payload(Socket, Header = #header{type=?HEADERS}) ->
    http2_frame_headers:read_payload(Socket, Header);
read_payload(Socket, Header = #header{type=?SETTINGS}) ->
    http2_frame_settings:read_payload(Socket, Header);
read_payload(_Socket, #header{type=T}) ->
    lager:error("Unknown Header Type: ~p", [T]),
    {error, "bad header type"}.
