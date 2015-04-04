-module(http2_frame_headers).

-include("http2.hrl").

-behaviour(http2_frame).

-export([read_payload/2]).

read_payload(Socket, _Header = #header{flags=_F, length=Length}) ->
    {ok, Payload} = gen_tcp:recv(Socket, Length),
    lager:debug("HEADERS payload: ~p", [Payload]),
    Headers = hpack:decode(Payload),
    lager:debug("Headers: ~p", [Headers]),
    {ok, not_implemented}.