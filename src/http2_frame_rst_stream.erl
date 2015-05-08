-module(http2_frame_rst_stream).

-export([
    format/1,
    read_binary/2,
    to_binary/1
    ]).

-include("http2.hrl").

-behaviour(http2_frame).

-spec format(rst_stream()) -> iodata().
format(Payload) ->
    io_lib:format("[RST Stream: ~p]", [Payload]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} |
    {error, term()}.
read_binary(_, #frame_header{stream_id=0}) ->
    {error, connection_error};
read_binary(<<ErrorCode:4,Rem/bits>>, #frame_header{length=4}) ->
    Payload = #rst_stream{
                 error_code = ErrorCode
                },
    {ok, Payload, Rem};
read_binary(_, #frame_header{stream_id=0}) ->
    {error, frame_size_error}.

-spec to_binary(rst_stream()) -> iodata().
to_binary(#rst_stream{error_code=C}) ->
    <<C:32>>.
