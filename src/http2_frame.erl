-module(http2_frame).

-include("http2.hrl").

-export([
         recv/1,
         read/1,
         read/2,
         read_binary_frame_header/1,
         read_binary_payload/2,
         from_binary/1,
         format_header/1,
         format_payload/1,
         format/1,
         to_binary/1,
         header_to_binary/1
]).

%% Each frame type should be able to be read off a binary stream. If
%% the header is good, then it'll know how many more bytes to take off
%% the stream for the payload. If there are more bytes left over, it's
%% the next header, so we should return a tuple that contains the
%% remainder as well.
-callback read_binary(Bin::binary(),
                      Header::frame_header()) ->
    {ok, payload(), Remainder::binary()} | {error, term()}.

%% For io:formating
-callback format(payload()) -> iodata().

%% convert payload to binary
-callback to_binary(payload()) -> iodata().

%% TODO: some kind of callback for sending frames
%-callback send(port(), payload()) -> ok | {error, term()}.


%% for http2_socket
-spec recv(binary() |
           {frame_header(), binary()}) ->
                  {ok, frame(), binary()}
                | {error, not_enoguh_header, binary()}
                | {error, not_enough_payload, frame_header(), binary()}
                | {error, error_code()}.
recv(Bin)
  when is_binary(Bin), byte_size(Bin) < 9 ->
    {error, not_enough_header, Bin};
recv(Bin)
  when is_binary(Bin) ->
    {Header, PayloadBin} = read_binary_frame_header(Bin),
    recv({Header, PayloadBin});
recv({Header, PayloadBin})
  when byte_size(PayloadBin) < Header#frame_header.length ->
    {error, not_enough_payload, Header, PayloadBin};
recv({Header, PayloadBin}) ->
    case read_binary_payload(PayloadBin, Header) of
        {ok, Payload, Rem} ->
            {ok, {Header, Payload}, Rem};
        {error, Code} ->
            {error, Code}
    end.

-spec read(socket()) -> {frame_header(), payload()}.
read(Socket) ->
    read(Socket, infinity).

-spec read(socket(), timeout()) -> frame() | {error, closed|inet:posix()}.
read(Socket, Timeout) ->
    case read_header(Socket, Timeout) of
        {error, Reason} ->
            {error, Reason};
        FrameHeader ->
            {ok, Payload} = read_payload(Socket, FrameHeader, Timeout),
            lager:debug(format({FrameHeader, Payload})),
            {FrameHeader, Payload}
    end.

%% Hi, it's been a while. We need to massage the API here into
%% something that can handle an unknown number of bytes in a binary
%% containing an unknown quantity of frames

-spec from_binary(binary()) -> [{frame_header(), payload()}].
from_binary(Bin) ->
    from_binary(Bin, []).

from_binary(<<>>, Acc) ->
    Acc;
from_binary(Bin, Acc) ->
    {Header, PayloadBin} = read_binary_frame_header(Bin),
    {ok, Payload, Rem} = read_binary_payload(PayloadBin, Header),
    from_binary(Rem, [{Header, Payload}|Acc]).

-spec format_header(frame_header()) -> iodata().
format_header(#frame_header{
        length = Length,
        type = Type,
        flags = Flags,
        stream_id = StreamId
    }) ->
    io_lib:format("[Frame Header: L:~p, T:~p, F:~p, StrId:~p]", [Length, ?FT(Type), Flags, StreamId]).

-spec read_header(socket(), timeout()) -> frame_header() | {error, closed|inet:posix()}.
read_header({Transport, Socket}, Timeout) ->
    case Transport:recv(Socket, 9, Timeout) of
        {ok, HeaderBytes} ->
            {Header, <<>>} = read_binary_frame_header(HeaderBytes),
            Header;
        E -> E
    end.

-spec read_binary_frame_header(binary()) -> {frame_header(), binary()}.
read_binary_frame_header(<<Length:24,Type:8,Flags:8,_R:1,StreamId:31,Rem/bits>>) ->
    Header = #frame_header{
        length = Length,
        type = Type,
        flags = Flags,
        stream_id = StreamId
    },
    {Header, Rem}.

-spec read_payload(socket(), frame_header(), timeout()) ->
    {ok, payload()} | {error, closed|inet:posix()}.
read_payload(_, Header=#frame_header{length=0}, _Timeout) ->
    {ok, FramePayload, <<>>} = read_binary_payload(<<>>, Header),
    {ok, FramePayload};
read_payload({Transport, Socket}, Header=#frame_header{length=L}, Timeout) ->
    case Transport:recv(Socket, L, Timeout) of
        {ok, DataBin} ->
            {ok, FramePayload, <<>>} = read_binary_payload(DataBin, Header),
            {ok, FramePayload};
        E -> E
    end.

-spec read_binary_payload(binary(), frame_header()) ->
    {ok, payload(), binary()} | {error, error_code()}.
read_binary_payload(Bin, Header = #frame_header{type=?DATA}) ->
    http2_frame_data:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?HEADERS}) ->
    http2_frame_headers:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?PRIORITY}) ->
    http2_frame_priority:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?RST_STREAM}) ->
    http2_frame_rst_stream:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?SETTINGS}) ->
    http2_frame_settings:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?PUSH_PROMISE}) ->
    http2_frame_push_promise:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?PING}) ->
    http2_frame_ping:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?GOAWAY}) ->
    http2_frame_goaway:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?WINDOW_UPDATE}) ->
    http2_frame_window_update:read_binary(Bin, Header);
read_binary_payload(Bin, Header = #frame_header{type=?CONTINUATION}) ->
    http2_frame_continuation:read_binary(Bin, Header);
read_binary_payload(Bin, Header) ->
    read_unsupported_frame_binary(Bin, Header).

read_unsupported_frame_binary(Bin,
                              #frame_header{length=0}) ->
    {ok, <<>>, Bin};
read_unsupported_frame_binary(Bin,
                              #frame_header{length=L}) ->
    <<PayloadBin:L/binary,Rem/bits>> = Bin,
    {ok, PayloadBin, Rem}.

-spec format_payload(frame()) -> iodata().
format_payload({#frame_header{type=?DATA}, P}) ->
    http2_frame_data:format(P);
format_payload({#frame_header{type=?HEADERS}, P}) ->
    http2_frame_headers:format(P);
format_payload({#frame_header{type=?PRIORITY}, P}) ->
    http2_frame_priority:format(P);
format_payload({#frame_header{type=?RST_STREAM}, P}) ->
    http2_frame_rst_stream:format(P);
format_payload({#frame_header{type=?SETTINGS}, P}) ->
    http2_frame_settings:format(P);
format_payload({#frame_header{type=?PUSH_PROMISE}, P}) ->
    http2_frame_push_promise:format(P);
format_payload({#frame_header{type=?PING}, P}) ->
    http2_frame_ping:format(P);
format_payload({#frame_header{type=?GOAWAY}, P}) ->
    http2_frame_goaway:format(P);
format_payload({#frame_header{type=?WINDOW_UPDATE}, P}) ->
    http2_frame_window_update:format(P);
format_payload({#frame_header{type=?CONTINUATION}, P}) ->
    http2_frame_continuation:format(P);
format_payload({_, _P}) ->
    "Unsupported Frame".



-spec format(frame()) -> iodata().
format(error) -> "error";
format({error, E}) -> io_lib:format("error : ~p",[E]);
format({Header, Payload}) ->
    lists:flatten(io_lib:format("~s | ~s", [format_header(Header), format_payload({Header, Payload})]));
format(<<>>) -> "".

-spec to_binary(frame()) -> iodata().
to_binary({Header, Payload}) ->
    {Type, PayloadBin} = payload_to_binary(Payload),
    NewHeader = Header#frame_header{
                  length = iodata_size(PayloadBin),
                  type = Type
                 },
    HeaderBin = header_to_binary(NewHeader),
    [HeaderBin, PayloadBin].

-spec header_to_binary(frame_header()) -> iodata().
header_to_binary(#frame_header{
        length=L,
        type=T,
        flags=F,
        stream_id=StreamId
    }) ->
    <<L:24,T:8,F:8,0:1,StreamId:31>>.

-spec payload_to_binary(payload()) -> {frame_type(), iodata()}.
payload_to_binary(P=#data{})          -> {?DATA, http2_frame_data:to_binary(P)};
payload_to_binary(P=#headers{})       -> {?HEADERS, http2_frame_headers:to_binary(P)};
payload_to_binary(P=#priority{})      -> {?PRIORITY, http2_frame_priority:to_binary(P)};
payload_to_binary(P=#rst_stream{})    -> {?RST_STREAM, http2_frame_rst_stream:to_binary(P)};
payload_to_binary(P=#settings{})      -> {?SETTINGS, http2_frame_settings:to_binary(P)};
payload_to_binary(P=#push_promise{})  -> {?PUSH_PROMISE, http2_frame_push_promise:to_binary(P)};
payload_to_binary(P=#ping{})          -> {?PING, http2_frame_ping:to_binary(P)};
payload_to_binary(P=#goaway{})        -> {?GOAWAY, http2_frame_goaway:to_binary(P)};
payload_to_binary(P=#window_update{}) -> {?WINDOW_UPDATE, http2_frame_window_update:to_binary(P)};
payload_to_binary(P=#continuation{})  -> {?CONTINUATION, http2_frame_continuation:to_binary(P)}.

iodata_size(L) when is_list(L) ->
    lists:foldl(fun(X, Acc) ->
                        Acc + iodata_size(X)
                end, 0, L);
iodata_size(B) when is_binary(B) ->
    byte_size(B).
