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
    {ok, L} = gen_tcp:recv(Socket, 3),
    Length = binary:decode_unsigned(L),
    lager:debug("Length: ~p", [Length]),
    {ok, T} = gen_tcp:recv(Socket, 1),
    Type = binary:decode_unsigned(T),
    lager:debug("Type: ~p", [Type]),
    {ok, Flags} = gen_tcp:recv(Socket, 1),
    lager:debug("Flags: ~p", [Flags]),
    %TODO: Actually the first bit here is R, some HTTP/2
    % thing that currently is always 0 so it's easier to
    % just read all 4 bytes into stream ID
    % WARNING: NOT TO EXACT SPEC, but won't hurt
    %{ok, R} = gen_tcp:recv(Socket, 1),
    %lager:debug("R: ~p", [R]),
    {ok, StreamId} = gen_tcp:recv(Socket, 4),
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