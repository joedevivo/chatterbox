-module(http2_frame_push_promise).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
    format/1,
    read_binary/2,
    to_binary/1
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

-spec to_binary(push_promise()) -> iodata().
to_binary(#push_promise{
             promised_stream_id=PSID,
             block_fragment=BF
            }) ->
    %% TODO: allow for padding as per HTTP/2 SPEC
    <<0:1,PSID:31,BF/binary>>.
