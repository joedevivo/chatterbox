-module(http2_frame_settings).

-include("http2.hrl").

-behaviour(http2_frame).

-export([read_payload/2]).

read_payload(Socket, _Header = #header{length=Length}) ->
    {ok, Payload} = gen_tcp:recv(Socket, Length),
    Settings = parse_settings(Payload),
    lager:debug("Settings: ~p", [Settings]),
    {ok, Settings}.

-spec parse_settings(binary()) -> settings().
parse_settings(Bin) ->
    parse_settings(Bin, #settings{}).

-spec parse_settings(binary(), port()) -> settings().
parse_settings(<<0,3,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, S#settings{max_concurrent_streams=binary:decode_unsigned(Val)});
parse_settings(<<0,4,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, S#settings{initial_window_size=binary:decode_unsigned(Val)});
parse_settings(<<>>, Settings) ->
    Settings.