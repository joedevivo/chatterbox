-module(http2_frame_push_promise).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
    format/1,
    read_binary/2
    ]).

-spec format(push_promise()) -> iodata().
format(Payload) ->
    io_lib:format("[Headers: ~p]", [Payload]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} | {error, term()}.
read_binary(Bin, H=#frame_header{length=L}) ->
    <<PayloadBin:L/binary,Rem/binary>> = Bin,
    Data = http2_padding:read_possibly_padded_payload(PayloadBin, H),
    <<_R:1,Stream:31,BlockFragment/bits>> = Data,
    Payload = #push_promise{
                 promised_stream_id=Stream,
                 block_fragment=BlockFragment
                },
    {ok, Payload, Rem}.
