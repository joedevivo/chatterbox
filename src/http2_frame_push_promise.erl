-module(http2_frame_push_promise).

-include("http2.hrl").

-behavior(http2_frame).

-export([read_payload/2]).

-spec read_payload(socket(), frame_header()) -> {ok, payload()} | {error, term()}.
read_payload(Socket, Header) ->
    Data = http2_padding:read_possibly_padded_payload(Socket, Header),
    <<_R:1,Stream:31,BlockFragment/bits>> = Data,
    Payload = #push_promise{
                 promised_stream_id=Stream,
                 block_fragment=BlockFragment
                },
    {ok, Payload}.
