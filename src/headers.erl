-module(headers).

-export([new/0, add/3, lookup/2]).

-type header_name() :: atom().
-type header_value():: binary().
-type header() :: {header_name(), header_value()}.

-define(DYNAMIC_TABLE_MIN_INDEX, 62).

-record(dynamic_table, {
    table = [] :: [{pos_integer(), header_name(), header_value()}]
    }).
-type dynamic_table() :: #dynamic_table{}.

-spec new() -> dynamic_table().
new() -> #dynamic_table{}.

-spec add(header_name(), header_value(), dynamic_table()) -> dynamic_table().
add(Name, Value, DT=#dynamic_table{table=T}) ->
    TPlus = lists:map(fun({N,H,V}) -> {N+1, H,V} end, T),
    DT#dynamic_table{table=[{?DYNAMIC_TABLE_MIN_INDEX, Name, Value}|TPlus]}.

%-spec get_index(header_name(), dynamic_table()) ->
%    undefined | pos_integer().
%get_index(Name, #dynamic_table{table=T}) ->
%    case lists:keyfind(Name, 2, T) of
%        false ->
%            undefined;
%        {N, Name, _V} ->
%            N
%    end.
%
%-spec get_name(pos_integer(), dynamic_table()) -> header_name() | undefined.
%get
%
%get_name(1, _) -> ':authority';
%get_name(2, _) -> ':method';
%get_name(3, _) -> ':method';
%get_name(4, _) -> ':path';
%get_name(5, _) -> ':path';
%get_name(6, _) -> ':scheme';
%get_name(7, _) -> ':scheme';
%get_name(16, _) -> 'accept-encoding';
%get_name(19, _) -> 'accept';
%get_name(24)
%get_name(58, _) -> 'user-agent';
%
%get_name(Idx, #dynamic_table{table=T}) ->
%    case lists:keyfind(Idx, 1, T) of
%        false ->
%            undefined;
%        {Idx, Name, _V} ->
%            Name
%    end.
%
-spec lookup(pos_integer(), dynamic_table()) -> header().
lookup(1 , _) -> {':authority', ""};
lookup(2 , _) -> {':method', <<"GET">>};
lookup(3 , _) -> {':method', <<"POST">>};
lookup(4 , _) -> {':path', <<"/">>};
lookup(5 , _) -> {':path', <<"/index.html">>};
lookup(6 , _) -> {':scheme', <<"http">>};
lookup(7 , _) -> {':scheme', <<"https">>};
lookup(8 , _) -> {':status', <<"200">>};
lookup(9 , _) -> {':status', <<"204">>};
lookup(10, _) -> {':status', <<"206">>};
lookup(11, _) -> {':status', <<"304">>};
lookup(12, _) -> {':status', <<"400">>};
lookup(13, _) -> {':status', <<"404">>};
lookup(14, _) -> {':status', <<"500">>};
lookup(15, _) -> {'accept-charset', ""};
lookup(16, _) -> {'accept-encoding', <<"gzip, deflate">>};
lookup(17, _) -> {'accept-language', ""};
lookup(18, _) -> {'accept-ranges', ""};
lookup(19, _) -> {'accept', ""};
lookup(20, _) -> {'access-control-allow-origin', ""};
lookup(21, _) -> {'age', ""};
lookup(22, _) -> {'allow', ""};
lookup(23, _) -> {'authorization', ""};
lookup(24, _) -> {'cache-control', ""};
lookup(25, _) -> {'content-disposition', ""};
lookup(26, _) -> {'content-encoding', ""};
lookup(27, _) -> {'content-language', ""};
lookup(28, _) -> {'content-length', ""};
lookup(29, _) -> {'content-location', ""};
lookup(30, _) -> {'content-range', ""};
lookup(31, _) -> {'content-type', ""};
lookup(32, _) -> {'cookie', ""};
lookup(33, _) -> {'date', ""};
lookup(34, _) -> {'etag', ""};
lookup(35, _) -> {'expect', ""};
lookup(36, _) -> {'expires', ""};
lookup(37, _) -> {'from', ""};
lookup(38, _) -> {'host', ""};
lookup(39, _) -> {'if-match', ""};
lookup(40, _) -> {'if-modified-since', ""};
lookup(41, _) -> {'if-none-match', ""};
lookup(42, _) -> {'if-range', ""};
lookup(43, _) -> {'if-unmodified-since', ""};
lookup(44, _) -> {'last-modified', ""};
lookup(45, _) -> {'link', ""};
lookup(46, _) -> {'location', ""};
lookup(47, _) -> {'max-forwards', ""};
lookup(48, _) -> {'proxy-authenticate', ""};
lookup(49, _) -> {'proxy-authorization', ""};
lookup(50, _) -> {'range', ""};
lookup(51, _) -> {'referer', ""};
lookup(52, _) -> {'refresh', ""};
lookup(53, _) -> {'retry-after', ""};
lookup(54, _) -> {'server', ""};
lookup(55, _) -> {'set-cookie', ""};
lookup(56, _) -> {'strict-transport-security', ""};
lookup(57, _) -> {'transfer-encoding', ""};
lookup(58, _) -> {'user-agent', ""};
lookup(59, _) -> {'vary', ""};
lookup(60, _) -> {'via', ""};
lookup(61, _) -> {'www-authenticate', ""};
lookup(Idx, #dynamic_table{table=T}) ->
    case lists:keyfind(Idx, 1, T) of
        false ->
            undefined;
        {Idx, Name, V} ->
            {Name, V}
    end.