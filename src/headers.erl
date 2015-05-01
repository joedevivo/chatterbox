-module(headers).

-include("http2.hrl").

-export([
    new/0,
    new/1,
    add/3,
    lookup/2,
    resize/2,
    table_size/1,
    match/2
]).

-type header_name() :: binary().
-type header_value():: binary().
-type header() :: {header_name(), header_value()}.
-export_type([header/0]).

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

-spec match(header(), dynamic_table()) -> {atom(), pos_integer()}.
match({<<":authority">>, <<>>}, _) ->                     {indexed, 1 };
match({<<":method">>, <<"GET">>}, _) ->                   {indexed, 2 };
match({<<":method">>, <<"POST">>}, _) ->                  {indexed, 3 };
match({<<":path">>, <<"/">>}, _) ->                       {indexed, 4 };
match({<<":path">>, <<"/index.html">>}, _) ->             {indexed, 5 };
match({<<":scheme">>, <<"http">>}, _) ->                  {indexed, 6 };
match({<<":scheme">>, <<"https">>}, _) ->                 {indexed, 7 };
match({<<":status">>, <<"200">>}, _) ->                   {indexed, 8 };
match({<<":status">>, <<"204">>}, _) ->                   {indexed, 9 };
match({<<":status">>, <<"206">>}, _) ->                   {indexed, 10};
match({<<":status">>, <<"304">>}, _) ->                   {indexed, 11};
match({<<":status">>, <<"400">>}, _) ->                   {indexed, 12};
match({<<":status">>, <<"404">>}, _) ->                   {indexed, 13};
match({<<":status">>, <<"500">>}, _) ->                   {indexed, 14};
match({<<"accept-charset">>, <<>>}, _) ->                 {indexed, 15};
match({<<"accept-encoding">>, <<"gzip, deflate">>}, _) -> {indexed, 16};
match({<<"accept-language">>, <<>>}, _) ->                {indexed, 17};
match({<<"accept-ranges">>, <<>>}, _) ->                  {indexed, 18};
match({<<"accept">>, <<>>}, _) ->                         {indexed, 19};
match({<<"access-control-allow-origin">>, <<>>}, _) ->    {indexed, 20};
match({<<"age">>, <<>>}, _) ->                            {indexed, 21};
match({<<"allow">>, <<>>}, _) ->                          {indexed, 22};
match({<<"authorization">>, <<>>}, _) ->                  {indexed, 23};
match({<<"cache-control">>, <<>>}, _) ->                  {indexed, 24};
match({<<"content-disposition">>, <<>>}, _) ->            {indexed, 25};
match({<<"content-encoding">>, <<>>}, _) ->               {indexed, 26};
match({<<"content-language">>, <<>>}, _) ->               {indexed, 27};
match({<<"content-length">>, <<>>}, _) ->                 {indexed, 28};
match({<<"content-location">>, <<>>}, _) ->               {indexed, 29};
match({<<"content-range">>, <<>>}, _) ->                  {indexed, 30};
match({<<"content-type">>, <<>>}, _) ->                   {indexed, 31};
match({<<"cookie">>, <<>>}, _) ->                         {indexed, 32};
match({<<"date">>, <<>>}, _) ->                           {indexed, 33};
match({<<"etag">>, <<>>}, _) ->                           {indexed, 34};
match({<<"expect">>, <<>>}, _) ->                         {indexed, 35};
match({<<"expires">>, <<>>}, _) ->                        {indexed, 36};
match({<<"from">>, <<>>}, _) ->                           {indexed, 37};
match({<<"host">>, <<>>}, _) ->                           {indexed, 38};
match({<<"if-match">>, <<>>}, _) ->                       {indexed, 39};
match({<<"if-modified-since">>, <<>>}, _) ->              {indexed, 40};
match({<<"if-none-match">>, <<>>}, _) ->                  {indexed, 41};
match({<<"if-range">>, <<>>}, _) ->                       {indexed, 42};
match({<<"if-unmodified-since">>, <<>>}, _) ->            {indexed, 43};
match({<<"last-modified">>, <<>>}, _) ->                  {indexed, 44};
match({<<"link">>, <<>>}, _) ->                           {indexed, 45};
match({<<"location">>, <<>>}, _) ->                       {indexed, 46};
match({<<"max-forwards">>, <<>>}, _) ->                   {indexed, 47};
match({<<"proxy-authenticate">>, <<>>}, _) ->             {indexed, 48};
match({<<"proxy-authorization">>, <<>>}, _) ->            {indexed, 49};
match({<<"range">>, <<>>}, _) ->                          {indexed, 50};
match({<<"referer">>, <<>>}, _) ->                        {indexed, 51};
match({<<"refresh">>, <<>>}, _) ->                        {indexed, 52};
match({<<"retry-after">>, <<>>}, _) ->                    {indexed, 53};
match({<<"server">>, <<>>}, _) ->                         {indexed, 54};
match({<<"set-cookie">>, <<>>}, _) ->                     {indexed, 55};
match({<<"strict-transport-security">>, <<>>}, _) ->      {indexed, 56};
match({<<"transfer-encoding">>, <<>>}, _) ->              {indexed, 57};
match({<<"user-agent">>, <<>>}, _) ->                     {indexed, 58};
match({<<"vary">>, <<>>}, _) ->                           {indexed, 59};
match({<<"via">>, <<>>}, _) ->                            {indexed, 60};
match({<<"www-authenticate">>, <<>>}, _) ->               {indexed, 61};
match({Name, Value}, #dynamic_table{table=T}) ->
    %% If there's a N/V match in the DT, return {indexed, Int}
    %% If there's a N match, make sure there's not also a static_match
        %% if so, use it, otherwise use the first element in the first match
        %% If not
    Found = lists:filter(fun({_,N,_}) -> N =:= Name end, T),
    ExactFound = lists:filter(fun({_,_,V}) -> V =:= Value end, Found),

    case {ExactFound, Found, static_match(Name)} of
        {[{I,Name,Value}|_], _, _} ->
            {indexed, I};
        {[], [{I,Name,_}|_], undefined} ->
            {literal_with_indexing, I};
        {[], _, I} when is_integer(I) ->
            {literal_with_indexing, I};
        {[], [], undefined} ->
            {literal_wo_indexing, undefined}
    end.

-spec static_match(header_name()) -> pos_integer().
static_match(<<":authority">>) ->                      1 ;
static_match(<<":method">>) ->                         2 ;
static_match(<<":path">>) ->                           4 ;
static_match(<<":scheme">>) ->                         6 ;
static_match(<<":status">>) ->                         8 ;
static_match(<<"accept-charset">>) ->                  15;
static_match(<<"accept-encoding">>) ->                 16;
static_match(<<"accept-language">>) ->                 17;
static_match(<<"accept-ranges">>) ->                   18;
static_match(<<"accept">>) ->                          19;
static_match(<<"access-control-allow-origin">>) ->     20;
static_match(<<"age">>) ->                             21;
static_match(<<"allow">>) ->                           22;
static_match(<<"authorization">>) ->                   23;
static_match(<<"cache-control">>) ->                   24;
static_match(<<"content-disposition">>) ->             25;
static_match(<<"content-encoding">>) ->                26;
static_match(<<"content-language">>) ->                27;
static_match(<<"content-length">>) ->                  28;
static_match(<<"content-location">>) ->                29;
static_match(<<"content-range">>) ->                   30;
static_match(<<"content-type">>) ->                    31;
static_match(<<"cookie">>) ->                          32;
static_match(<<"date">>) ->                            33;
static_match(<<"etag">>) ->                            34;
static_match(<<"expect">>) ->                          35;
static_match(<<"expires">>) ->                         36;
static_match(<<"from">>) ->                            37;
static_match(<<"host">>) ->                            38;
static_match(<<"if-match">>) ->                        39;
static_match(<<"if-modified-since">>) ->               40;
static_match(<<"if-none-match">>) ->                   41;
static_match(<<"if-range">>) ->                        42;
static_match(<<"if-unmodified-since">>) ->             43;
static_match(<<"last-modified">>) ->                   44;
static_match(<<"link">>) ->                            45;
static_match(<<"location">>) ->                        46;
static_match(<<"max-forwards">>) ->                    47;
static_match(<<"proxy-authenticate">>) ->              48;
static_match(<<"proxy-authorization">>) ->             49;
static_match(<<"range">>) ->                           50;
static_match(<<"referer">>) ->                         51;
static_match(<<"refresh">>) ->                         52;
static_match(<<"retry-after">>) ->                     53;
static_match(<<"server">>) ->                          54;
static_match(<<"set-cookie">>) ->                      55;
static_match(<<"strict-transport-security">>) ->       56;
static_match(<<"transfer-encoding">>) ->               57;
static_match(<<"user-agent">>) ->                      58;
static_match(<<"vary">>) ->                            59;
static_match(<<"via">>) ->                             60;
static_match(<<"www-authenticate">>) ->                61;
static_match(_) ->                                     undefined.
