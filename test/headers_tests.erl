-module(headers_tests).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all]).

resize_test() ->
    DT = headers:new(64),
    DT2 = headers:add(<<"four">>,<<"four">>,DT),
    ?assertEqual(40, headers:table_size(DT2)),
    DT3 = headers:add(<<"--eight-">>,<<"--eight-">>,DT2),
    ?assertEqual(48, headers:table_size(DT3)),
    ok.