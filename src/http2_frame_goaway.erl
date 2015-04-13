-module(http2_frame_goaway).

-include("http2.hrl").

-behavior(http2_frame).

-export([read_binary/2]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary(Bin, #frame_header{length=L}) ->
    <<Data:L/binary,Rem/bits>> = Bin,
    <<_R:1,LastStream:31,ErrorCode:32,Extra/bits>> = Data,
    Payload = #goaway{
                 last_stream_id = LastStream,
                 error_code = ErrorCode,
                 additional_debug_data = Extra
                },
    {ok, Payload, Rem}.
