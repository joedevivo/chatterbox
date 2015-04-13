-module(http2_frame_ping).

-include("http2.hrl").

-behavior(http2_frame).

-export([read_payload/2]).

-spec read_payload(socket(), frame_header()) -> {ok, payload()} | {error, term()}.
read_payload({Transport, Socket}, #header{length=8}) ->
    {ok, Data} = Transport:recv(Socket, 8),
    Payload = #ping{
                 opaque_data = Data
                },
    {ok, Payload, <<>>}.
