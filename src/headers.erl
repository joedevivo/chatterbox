-module(headers).

-include("http2.hrl").

-export([
    new/0,
    new/1,
    add/3,
    lookup/2,
    resize/2,
    table_size/1
]).

-type header_name() :: binary().
-type header_value():: binary().
-type header() :: {header_name(), header_value()}.

-define(DYNAMIC_TABLE_MIN_INDEX, 62).

-record(dynamic_table, {
    table = [] :: [{pos_integer(), header_name(), header_value()}],
    max_size = 4096 :: pos_integer(),
    size = 0 :: non_neg_integer()
    }).
-type dynamic_table() :: #dynamic_table{}.

-spec new() -> dynamic_table().
new() -> #dynamic_table{}.

-spec new(pos_integer()) -> dynamic_table().
new(S) -> #dynamic_table{max_size=S}.

-spec entry_size({pos_integer(), header_name(), header_value()}) -> pos_integer().
entry_size({_, Name, Value}) ->
    entry_size(Name, Value).

-spec entry_size(header_name(), header_value()) -> pos_integer().
entry_size(Name, Value) ->
    32 + size(Name) + size(Value).

-spec add(header_name(), header_value(), dynamic_table()) -> dynamic_table().
add(Name, Value, DT) ->
    add(Name, Value, entry_size(Name, Value), DT).

-spec add(header_name(), header_value(), pos_integer(), dynamic_table()) -> dynamic_table().
add(Name, Value, EntrySize, DT=#dynamic_table{table=T, size=S, max_size=MS})
    when EntrySize + S =< MS ->
    TPlus = lists:map(fun({N,H,V}) -> {N+1, H,V} end, T),
    DT#dynamic_table{size=S+EntrySize, table=[{?DYNAMIC_TABLE_MIN_INDEX, Name, Value}|TPlus]};
add(Name, Value, EntrySize, DT=#dynamic_table{size=S, max_size=MS})
    when EntrySize + S > MS ->
    add(Name, Value, EntrySize,
        droplast(DT)).

-spec droplast(dynamic_table()) -> dynamic_table().
droplast(DT=#dynamic_table{table=T, size=S}) ->
    [Last|NewTR] = lists:reverse(T),
    DT#dynamic_table{size=S-entry_size(Last), table=lists:reverse(NewTR)}.

-spec lookup(pos_integer(), dynamic_table()) -> header().
lookup(1 , _) -> {<<":authority">>, <<>>};
lookup(2 , _) -> {<<":method">>, <<"GET">>};
lookup(3 , _) -> {<<":method">>, <<"POST">>};
lookup(4 , _) -> {<<":path">>, <<"/">>};
lookup(5 , _) -> {<<":path">>, <<"/index.html">>};
lookup(6 , _) -> {<<":scheme">>, <<"http">>};
lookup(7 , _) -> {<<":scheme">>, <<"https">>};
lookup(8 , _) -> {<<":status">>, <<"200">>};
lookup(9 , _) -> {<<":status">>, <<"204">>};
lookup(10, _) -> {<<":status">>, <<"206">>};
lookup(11, _) -> {<<":status">>, <<"304">>};
lookup(12, _) -> {<<":status">>, <<"400">>};
lookup(13, _) -> {<<":status">>, <<"404">>};
lookup(14, _) -> {<<":status">>, <<"500">>};
lookup(15, _) -> {<<"accept-charset">>, <<>>};
lookup(16, _) -> {<<"accept-encoding">>, <<"gzip, deflate">>};
lookup(17, _) -> {<<"accept-language">>, <<>>};
lookup(18, _) -> {<<"accept-ranges">>, <<>>};
lookup(19, _) -> {<<"accept">>, <<>>};
lookup(20, _) -> {<<"access-control-allow-origin">>, <<>>};
lookup(21, _) -> {<<"age">>, <<>>};
lookup(22, _) -> {<<"allow">>, <<>>};
lookup(23, _) -> {<<"authorization">>, <<>>};
lookup(24, _) -> {<<"cache-control">>, <<>>};
lookup(25, _) -> {<<"content-disposition">>, <<>>};
lookup(26, _) -> {<<"content-encoding">>, <<>>};
lookup(27, _) -> {<<"content-language">>, <<>>};
lookup(28, _) -> {<<"content-length">>, <<>>};
lookup(29, _) -> {<<"content-location">>, <<>>};
lookup(30, _) -> {<<"content-range">>, <<>>};
lookup(31, _) -> {<<"content-type">>, <<>>};
lookup(32, _) -> {<<"cookie">>, <<>>};
lookup(33, _) -> {<<"date">>, <<>>};
lookup(34, _) -> {<<"etag">>, <<>>};
lookup(35, _) -> {<<"expect">>, <<>>};
lookup(36, _) -> {<<"expires">>, <<>>};
lookup(37, _) -> {<<"from">>, <<>>};
lookup(38, _) -> {<<"host">>, <<>>};
lookup(39, _) -> {<<"if-match">>, <<>>};
lookup(40, _) -> {<<"if-modified-since">>, <<>>};
lookup(41, _) -> {<<"if-none-match">>, <<>>};
lookup(42, _) -> {<<"if-range">>, <<>>};
lookup(43, _) -> {<<"if-unmodified-since">>, <<>>};
lookup(44, _) -> {<<"last-modified">>, <<>>};
lookup(45, _) -> {<<"link">>, <<>>};
lookup(46, _) -> {<<"location">>, <<>>};
lookup(47, _) -> {<<"max-forwards">>, <<>>};
lookup(48, _) -> {<<"proxy-authenticate">>, <<>>};
lookup(49, _) -> {<<"proxy-authorization">>, <<>>};
lookup(50, _) -> {<<"range">>, <<>>};
lookup(51, _) -> {<<"referer">>, <<>>};
lookup(52, _) -> {<<"refresh">>, <<>>};
lookup(53, _) -> {<<"retry-after">>, <<>>};
lookup(54, _) -> {<<"server">>, <<>>};
lookup(55, _) -> {<<"set-cookie">>, <<>>};
lookup(56, _) -> {<<"strict-transport-security">>, <<>>};
lookup(57, _) -> {<<"transfer-encoding">>, <<>>};
lookup(58, _) -> {<<"user-agent">>, <<>>};
lookup(59, _) -> {<<"vary">>, <<>>};
lookup(60, _) -> {<<"via">>, <<>>};
lookup(61, _) -> {<<"www-authenticate">>, <<>>};
lookup(Idx, #dynamic_table{table=T}) ->
    case lists:keyfind(Idx, 1, T) of
        false ->
            undefined;
        {Idx, Name, V} ->
            {Name, V}
    end.

-spec resize(pos_integer(), dynamic_table()) -> dynamic_table().
resize(NewSize, DT=#dynamic_table{size=S})
    when NewSize =< S ->
        DT#dynamic_table{max_size=NewSize};
resize(NewSize, DT) ->
    resize(NewSize, droplast(DT)).


-spec table_size(dynamic_table()) -> pos_integer().
table_size(#dynamic_table{size=S}) -> S.




