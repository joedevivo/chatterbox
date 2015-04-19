-module(http2_frame_window_update).

-include("http2.hrl").

-behavior(http2_frame).

-export([
         read_binary/2,
         send/3
]).

-spec read_binary(Bin::binary(),
                      Header::frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary(Bin, #frame_header{length=4}) ->
    <<_R:1,Increment:31,Rem/bits>> = Bin,
    Payload = #window_update{
                 window_size_increment=Increment
                },
    lager:debug("Window_Increment: ~p", [Increment]),
    {ok, Payload, Rem};
read_binary(_, _) ->
    {error, frame_size_error}.

send({Transport, Socket}, #window_update{window_size_increment=Payload}, StreamId) ->
    lager:debug("Window update payload: ~p", [Payload]),
    Transport:send(Socket, [
        <<4:24,?WINDOW_UPDATE:8,0:8,0:1,StreamId:31>>,
        <<0:1,Payload:31>>]).
