-module(http2_frame_rst_stream).

-export([read_payload/2]).

-include("http2.hrl").

-behavior(http2_frame).

-spec read_payload(Socket :: socket(),
                   Header::header()) ->
    {ok, payload()} |
    {error, term()}.
read_payload(_, #header{stream_id=0}) ->
    {error, connection_error};
read_payload({Transport, Socket}, #header{length=4}) ->
    {ok, ErrorCode} = Transport:recv(Socket, 4),
    Payload = #rst_stream{
                 error_code = ErrorCode
                },
    {ok, Payload, <<>>};
read_payload(_, #header{stream_id=0}) ->
    {error, frame_size_error}.
