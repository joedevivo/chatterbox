-module(h2_frame_rst_stream).
-include("http2.hrl").
-behaviour(h2_frame).

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
-type frame() :: {h2_frame:header(), payload()}.
-export_type([payload/0, frame/0]).

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

-spec read_binary(binary(), h2_frame:header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(_,
            #frame_header{
               stream_id=0
               }) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
read_binary(_,
            #frame_header{
               length=L
              })
  when L =/= 4 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
read_binary(<<ErrorCode:32,Rem/bits>>, #frame_header{length=4}) ->
    Payload = #rst_stream{
                 error_code = ErrorCode
                },
    {ok, Payload, Rem}.

-spec to_binary(payload()) -> iodata().
to_binary(#rst_stream{error_code=C}) ->
    <<C:32>>.
