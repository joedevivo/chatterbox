-module(http2_frame_window_update).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
         format/1,
         read_binary/2,
         send/3,
         to_binary/1
]).

-spec format(window_update()) -> iodata().
format(Payload) ->
    io_lib:format("[Window Update: ~p]", [Payload]).

-spec read_binary(Bin::binary(),
                      Header::frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary(Bin, #frame_header{length=4}) ->
    <<_R:1,Increment:31,Rem/bits>> = Bin,
    Payload = #window_update{
                 window_size_increment=Increment
                },
    {ok, Payload, Rem};
read_binary(_, _) ->
    {error, frame_size_error}.

-spec send(sock:socket(),
           non_neg_integer(),
           stream_id()) ->
                  ok.
send(Socket, WindowSizeIncrement, StreamId) ->
    sock:send(Socket, [
                       <<4:24,?WINDOW_UPDATE:8,0:8,0:1,StreamId:31>>,
                       <<0:1,WindowSizeIncrement:31>>]).

-spec to_binary(window_update()) -> iodata().
to_binary(#window_update{
        window_size_increment=I
    }) ->
    <<0:1,I:31>>.
