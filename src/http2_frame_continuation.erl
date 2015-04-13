-module(http2_frame_continuation).

-include("http2.hrl").

-behavior(http2_frame).

-export([read_payload/2]).

-spec read_payload(socket(), frame_header()) -> {ok, payload()} | {error, term()}.
read_payload({Transport, Socket}, #header{length=Length}) ->
    {ok, Data} = Transport:recv(Socket, Length),
    Payload = #continuation{
                 block_fragment=Data
                },
    {ok, Payload, <<>>}.
