-module(http2_frame_goaway).

-include("http2.hrl").

-behavior(http2_frame).

-export([read_payload/2]).

-spec read_payload(socket(), frame_header()) -> {ok, payload()} | {error, term()}.
read_payload({Transport, Socket}, #header{length=L}) ->
    {ok, Data} = Transport:recv(Socket, L),
    <<_R:1,LastStream:31,ErrorCode:32,Extra/bits>> = Data,
    Payload = #goaway{
                 last_stream_id = LastStream,
                 error_code = ErrorCode,
                 additional_debug_data = Extra
                },
    {ok, Payload, <<>>}.
