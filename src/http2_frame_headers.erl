-module(http2_frame_headers).

-include("http2.hrl").

-behaviour(http2_frame).

-export([read_payload/2]).

-spec read_payload(socket(), frame_header()) -> {ok, payload()} | {error, term()}.
read_payload(Socket, Header) ->
    Data = http2_padding:read_possibly_padded_payload(Socket, Header),

    {Priority, HeaderFragment} = case is_priority(Header) of
        true ->
            http2_frame_priority:read_priority(Data);
        false ->
            {undefined, Data}
    end,

    Payload = #headers{
                 priority=Priority,
                 block_fragment=HeaderFragment
                },

    lager:debug("HEADERS payload: ~p", [Payload]),
    {ok, Payload}.

is_priority(#header{flags=F}) when F band ?FLAG_PRIORITY == 1 ->
    true;
is_priority(_) ->
    false.
