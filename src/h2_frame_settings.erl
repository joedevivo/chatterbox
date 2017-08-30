-module(h2_frame_settings).
-include("http2.hrl").
-behaviour(h2_frame).

-export(
   [
    format/1,
    read_binary/2,
    send/1,
    send/2,
    ack/0,
    ack/1,
    to_binary/1,
    overlay/2,
    validate/1
   ]).

%%TODO
-type payload() :: #settings{} | {settings, proplist()}.
-type frame() :: {h2_frame:header(), payload()}.

-type name() :: binary().
-type property() :: {name(), any()}.
-type proplist() :: [property()].

-export_type([payload/0, name/0, property/0, proplist/0, frame/0]).


-spec format(payload()
           | binary()
           | {settings, [proplists:property()]}
            ) -> iodata().
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

-spec read_binary(binary(), h2_frame:header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(Bin,
            #frame_header{
               length=0,
               stream_id=0
              }) ->
    {ok, {settings, []}, Bin};
read_binary(Bin,
            #frame_header{
               length=Length,
               stream_id=0
              }) ->
    <<SettingsBin:Length/binary,Rem/bits>> = Bin,
    Settings = parse_settings(SettingsBin),
    {ok, {settings, Settings}, Rem};
read_binary(_, _) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>}.


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
% An endpoint that receives a SETTINGS frame with any unknown or unsupported identifier 
% MUST ignore that setting
parse_settings(<<_:6/binary,T/binary>>, S)->
    parse_settings(T, S);
parse_settings(<<>>, Settings) ->
    Settings.

-spec overlay(payload(), {settings, [proplists:property()]}) -> payload().
overlay(S, Setting) ->
    overlay_(S, S, Setting).

overlay_(OriginalS, S, {settings, [{?SETTINGS_HEADER_TABLE_SIZE, Val}|PList]}) ->
    overlay_(OriginalS, S#settings{header_table_size=Val}, {settings, PList});
overlay_(OriginalS, S, {settings, [{?SETTINGS_ENABLE_PUSH, Val}|PList]}) ->
    overlay_(OriginalS, S#settings{enable_push=Val}, {settings, PList});
overlay_(OriginalS, S, {settings, [{?SETTINGS_MAX_CONCURRENT_STREAMS, Val}|PList]}) ->
    overlay_(OriginalS, S#settings{max_concurrent_streams=Val}, {settings, PList});
overlay_(OriginalS, S, {settings, [{?SETTINGS_INITIAL_WINDOW_SIZE, Val}|PList]}) ->
    overlay_(OriginalS, S#settings{initial_window_size=Val}, {settings, PList});
overlay_(OriginalS, S, {settings, [{?SETTINGS_MAX_FRAME_SIZE, Val}|PList]}) ->
    overlay_(OriginalS, S#settings{max_frame_size=Val}, {settings, PList});
overlay_(OriginalS, S, {settings, [{?SETTINGS_MAX_HEADER_LIST_SIZE, Val}|PList]}) ->
    overlay_(OriginalS, S#settings{max_header_list_size=Val}, {settings, PList});
overlay_(OriginalS, _S, {settings, [{_UnknownOrUnsupportedKey, _Val}|_]}) ->
    OriginalS;
overlay_(_OriginalS, S, {settings, []}) ->
    S.

-spec send(payload()) -> binary().
send(Settings) ->
    List = h2_settings:to_proplist(Settings),
    Payload = make_payload(List),
    L = size(Payload),
    Header = <<L:24,?SETTINGS:8,16#0:8,0:1,0:31>>,
    <<Header/binary, Payload/binary>>.

-spec send(payload(), payload()) -> binary().
send(PrevSettings, NewSettings) ->
    Diff = h2_settings:diff(PrevSettings, NewSettings),
    Payload = make_payload(Diff),
    L = size(Payload),
    Header = <<L:24,?SETTINGS:8,16#0:8,0:1,0:31>>,
    <<Header/binary, Payload/binary>>.

-spec make_payload(proplist()) -> binary().
make_payload(Diff) ->
    make_payload_(lists:reverse(Diff), <<>>).

make_payload_([], BinAcc) ->
    BinAcc;
make_payload_([{_, unlimited}|Tail], BinAcc) ->
    make_payload_(Tail, BinAcc);
make_payload_([{<<Setting>>, Value}|Tail], BinAcc) ->
    make_payload_(Tail, <<Setting:16,Value:32,BinAcc/binary>>).

-spec ack() -> binary().
ack() ->
    <<0:24,4:8,1:8,0:1,0:31>>.

-spec ack(socket()) -> ok | {error, term()}.
ack({Transport,Socket}) ->
    Transport:send(Socket, <<0:24,4:8,1:8,0:1,0:31>>).

-spec to_binary(payload()) -> iodata().
to_binary(#settings{}=Settings) ->
    [to_binary(S, Settings) || S <- ?SETTING_NAMES].

-spec to_binary(binary(), payload()) -> binary().
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


-spec validate({settings, [proplists:property()]}) -> ok | {error, integer()}.
validate({settings, PList}) ->
    validate_(PList).

validate_([]) ->
    ok;
validate_([{?SETTINGS_ENABLE_PUSH, Push}|_T])
  when Push > 1; Push < 0 ->
    {error, ?PROTOCOL_ERROR};
validate_([{?SETTINGS_INITIAL_WINDOW_SIZE, Size}|_T])
  when Size >=2147483648 ->
    {error, ?FLOW_CONTROL_ERROR};
validate_([{?SETTINGS_MAX_FRAME_SIZE, Size}|_T])
  when Size < 16384; Size > 16777215 ->
    {error, ?PROTOCOL_ERROR};
validate_([_H|T]) ->
    validate_(T).



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

make_payload_test() ->
    Diff = [
            {?SETTINGS_MAX_CONCURRENT_STREAMS, 2},
            {?SETTINGS_MAX_FRAME_SIZE, 2048}
           ],
    Bin = make_payload(Diff),
    <<MCSIndex>> = ?SETTINGS_MAX_CONCURRENT_STREAMS,
    <<MFSIndex>> = ?SETTINGS_MAX_FRAME_SIZE,
    ?assertEqual(<<MCSIndex:16,2:32,MFSIndex:16,2048:32>>, Bin),
    ok.

validate_test() ->
    ?assertEqual(ok, validate_([])),
    ?assertEqual(ok, validate_([{?SETTINGS_ENABLE_PUSH, 0}])),
    ?assertEqual(ok, validate_([{?SETTINGS_ENABLE_PUSH, 1}])),
    ?assertEqual({error, ?PROTOCOL_ERROR}, validate_([{?SETTINGS_ENABLE_PUSH, 2}])),
    ?assertEqual({error, ?PROTOCOL_ERROR}, validate_([{?SETTINGS_ENABLE_PUSH, -1}])),
    ?assertEqual({error, ?FLOW_CONTROL_ERROR}, validate_([{?SETTINGS_INITIAL_WINDOW_SIZE, 2147483648}])),
    ?assertEqual(ok, validate_([{?SETTINGS_INITIAL_WINDOW_SIZE, 2147483647}])),

    ?assertEqual({error, ?PROTOCOL_ERROR}, validate_([{?SETTINGS_MAX_FRAME_SIZE, 16383}])),
    ?assertEqual(ok, validate_([{?SETTINGS_MAX_FRAME_SIZE, 16384}])),

    ?assertEqual(ok, validate_([{?SETTINGS_MAX_FRAME_SIZE, 16777215}])),
    ?assertEqual({error, ?PROTOCOL_ERROR}, validate_([{?SETTINGS_MAX_FRAME_SIZE, 16777216}])),

    ok.

-endif.
