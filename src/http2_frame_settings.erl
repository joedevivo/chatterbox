-module(http2_frame_settings).

-include("http2.hrl").

-behaviour(http2_frame).

-export([
         format/1,
         read_binary/2,
         send/2,
         ack/1,
         to_binary/1,
         overlay/2
        ]).

-spec format(settings()|binary()|{settings, [proplists:property()]}) -> iodata().
format(<<>>) -> "Ack!";
format(#settings{
        header_table_size        = HTS,
        enable_push              = EP,
        max_concurrent_streams   = MCS,
        initial_window_size      = IWS,
        max_frame_size           = MFS,
        max_header_list_size     = MHLS
    }) ->
    lists:flatten(
        io_lib:format("[Settings: "
        " header_table_size        = ~p,"
        " enable_push              = ~p,"
        " max_concurrent_streams   = ~p,"
        " initial_window_size      = ~p,"
        " max_frame_size           = ~p,"
        " max_header_list_size     = ~p~n]", [HTS,EP,MCS,IWS,MFS,MHLS]));
format({settings, PList}) ->
    L = lists:map(fun({?SETTINGS_HEADER_TABLE_SIZE,V}) ->
                      {header_table_size,V};
                 ({?SETTINGS_ENABLE_PUSH,V}) ->
                      {enable_push,V};
                 ({?SETTINGS_MAX_CONCURRENT_STREAMS,V}) ->
                      {max_concurrent_streams,V};
                 ({?SETTINGS_INITIAL_WINDOW_SIZE,V}) ->
                      {initial_window_size, V};
                 ({?SETTINGS_MAX_FRAME_SIZE,V}) ->
                      {max_frame_size,V};
                 ({?SETTINGS_MAX_HEADER_LIST_SIZE,V}) ->
                      {max_header_list_size,V}
              end,
              PList),
    io_lib:format("~p", [L]).

-spec read_binary(binary(), frame_header()) ->
    {ok, payload(), binary()} |
    {error, term()}.
read_binary(Bin, _Header = #frame_header{length=0}) ->
    {ok, <<>>, Bin};
read_binary(Bin, _Header = #frame_header{length=Length}) ->
    <<SettingsBin:Length/binary,Rem/bits>> = Bin,
    Settings = parse_settings(SettingsBin),
    {ok, {settings, Settings}, Rem}.

-spec parse_settings(binary()) -> [proplists:property()].
parse_settings(Bin) ->
    lists:reverse(parse_settings(Bin, [])).

-spec parse_settings(binary(), [proplists:property()]) ->  [proplists:property()].
parse_settings(<<0,1,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, [{?SETTINGS_HEADER_TABLE_SIZE, binary:decode_unsigned(Val)}|S]);
parse_settings(<<0,2,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, [{?SETTINGS_ENABLE_PUSH, binary:decode_unsigned(Val)}|S]);
parse_settings(<<0,3,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, [{?SETTINGS_MAX_CONCURRENT_STREAMS, binary:decode_unsigned(Val)}|S]);
parse_settings(<<0,4,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, [{?SETTINGS_INITIAL_WINDOW_SIZE, binary:decode_unsigned(Val)}|S]);
parse_settings(<<0,5,Val:4/binary,T/binary>>, S) ->
    parse_settings(T, [{?SETTINGS_MAX_FRAME_SIZE, binary:decode_unsigned(Val)}|S]);
parse_settings(<<0,6,Val:4/binary,T/binary>>, S)->
    parse_settings(T, [{?SETTINGS_MAX_HEADER_LIST_SIZE, binary:decode_unsigned(Val)}|S]);
parse_settings(<<>>, Settings) ->
    Settings.

-spec overlay(settings(), {settings, [proplists:property()]}) -> settings().
overlay(S, {settings, [{?SETTINGS_HEADER_TABLE_SIZE, Val}|PList]}) ->
    overlay(S#settings{header_table_size=Val}, {settings, PList});
overlay(S, {settings, [{?SETTINGS_ENABLE_PUSH, Val}|PList]}) ->
    overlay(S#settings{enable_push=Val}, {settings, PList});
overlay(S, {settings, [{?SETTINGS_MAX_CONCURRENT_STREAMS, Val}|PList]}) ->
    overlay(S#settings{max_concurrent_streams=Val}, {settings, PList});
overlay(S, {settings, [{?SETTINGS_INITIAL_WINDOW_SIZE, Val}|PList]}) ->
    overlay(S#settings{initial_window_size=Val}, {settings, PList});
overlay(S, {settings, [{?SETTINGS_MAX_FRAME_SIZE, Val}|PList]}) ->
    overlay(S#settings{max_frame_size=Val}, {settings, PList});
overlay(S, {settings, [{?SETTINGS_MAX_HEADER_LIST_SIZE, Val}|PList]}) ->
    overlay(S#settings{max_header_list_size=Val}, {settings, PList});
overlay(S, {settings, []}) ->
    S.

-spec send(socket(), settings()) -> ok | {error, term()}.
send({Transport, Socket}, _Settings) ->
    %% TODO: hard coded settings frame. needs to be figured out from
    %% _Settings. Or not. We can have our own settings and they can be
    %% different.  Also needs to be compared to ?DEFAULT_SETTINGS and
    %% only send the ones that are different or maybe it's the fsm's
    %% current settings.  figure out later
    Header = <<12:24,?SETTINGS:8,16#0:8,0:1,0:31>>,

    Payload = <<3:16,
                100:32,
                4:16,
                65535:32>>,
    Frame = [Header, Payload],
    lager:debug("sending settings ~p", [Frame]),
    Transport:send(Socket, Frame).

-spec ack(socket()) -> ok | {error, term()}.
ack({Transport,Socket}) ->
    Transport:send(Socket, <<0:24,4:8,1:8,0:1,0:31>>).

-spec to_binary(settings()) -> iodata().
to_binary(#settings{}=Settings) ->
    [to_binary(S, Settings) || S <- ?SETTING_NAMES].

-spec to_binary(binary(), settings()) -> binary().
to_binary(?SETTINGS_HEADER_TABLE_SIZE, #settings{header_table_size=undefined}) ->
    <<>>;
to_binary(?SETTINGS_HEADER_TABLE_SIZE, #settings{header_table_size=HTS}) ->
    <<16#1:16,HTS:32>>;
to_binary(?SETTINGS_ENABLE_PUSH, #settings{enable_push=undefined}) ->
    <<>>;
to_binary(?SETTINGS_ENABLE_PUSH, #settings{enable_push=EP}) ->
    <<16#2:16,EP:32>>;
to_binary(?SETTINGS_MAX_CONCURRENT_STREAMS, #settings{max_concurrent_streams=undefined}) ->
    <<>>;
to_binary(?SETTINGS_MAX_CONCURRENT_STREAMS, #settings{max_concurrent_streams=MCS}) ->
    <<16#3:16,MCS:32>>;
to_binary(?SETTINGS_INITIAL_WINDOW_SIZE, #settings{initial_window_size=undefined}) ->
    <<>>;
to_binary(?SETTINGS_INITIAL_WINDOW_SIZE, #settings{initial_window_size=IWS}) ->
    <<16#4:16,IWS:32>>;
to_binary(?SETTINGS_MAX_FRAME_SIZE, #settings{max_frame_size=undefined}) ->
    <<>>;
to_binary(?SETTINGS_MAX_FRAME_SIZE, #settings{max_frame_size=MFS}) ->
    <<16#5:16,MFS:32>>;
to_binary(?SETTINGS_MAX_HEADER_LIST_SIZE, #settings{max_header_list_size=undefined}) ->
    <<>>;
to_binary(?SETTINGS_MAX_HEADER_LIST_SIZE, #settings{max_header_list_size=MHLS}) ->
    <<16#6:16,MHLS:32>>.
