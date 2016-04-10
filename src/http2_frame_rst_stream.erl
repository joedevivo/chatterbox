-module(http2_frame_rst_stream).
-include("http2.hrl").
-export([
         new/1,
         error_code/1,
         format/1,
         read_binary/2,
         to_binary/1
        ]).

-record(rst_stream, {
          error_code :: error_code()
}).
-type payload() :: #rst_stream{}.
-export_type([payload/0]).

-behaviour(http2_frame).

-spec new(error_code()) -> payload().
new(ErrorCode) ->
    #rst_stream{
       error_code=ErrorCode
      }.

-spec error_code(payload()) -> error_code().
error_code(#rst_stream{error_code=EC}) ->
    EC.

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[RST Stream: ~p]", [Payload]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()}.
read_binary(<<ErrorCode:32,Rem/bits>>, #frame_header{length=4}) ->
    Payload = #rst_stream{
                 error_code = ErrorCode
                },
    {ok, Payload, Rem};
read_binary(_, #frame_header{stream_id=0}) ->
    {error, frame_size_error}.

-spec to_binary(payload()) -> iodata().
to_binary(#rst_stream{error_code=C}) ->
    <<C:32>>.
