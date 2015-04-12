-module(http2_frame_window_update).

-include("http2.hrl").

-behavior(http2_frame).

-export([read_payload/2]).

-spec read_payload(socket(), frame_header()) -> {ok, payload()} | {error, term()}.
read_payload({Transport, Socket}, #header{length=4}) ->
    {ok, Data} = Transport:recv(Socket, 4),
    <<_R:1,Increment:31>> = Data,
    Payload = #window_update{
                 window_size_increment=Increment
                },
    {ok, Payload};
read_payload(_, _) ->
    {error, frame_size_error}.
