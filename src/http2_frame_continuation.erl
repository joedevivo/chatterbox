-module(http2_frame_continuation).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
    format/1,
    read_binary/2
    ]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary(Bin, #frame_header{length=Length}) ->
    <<Data:Length/binary,Rem/bits>> = Bin,
    Payload = #continuation{
                 block_fragment=Data
                },
    {ok, Payload, Rem}.

-spec format(continuation()) -> iodata().
format(Payload) ->
    io_lib:format("[Continuation: ~p ]", [Payload]).