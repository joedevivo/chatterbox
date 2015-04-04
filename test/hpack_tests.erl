-module(hpack_tests).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all]).

basic_nghttp2_request_test() ->
    PList = hpack:decode(<<130,132,134,65,138,160,228,29,19,157,9,184,240,30,7,83,3,42,47,42,144,122,138,170,105,210,154,196,192,23,117,119,127>>),
    % :method: GET
    % :path: /
    % :scheme: http
    % :authority: localhost:8080
    % accept: */*
    % accept-encoding: gzip, deflate
    % user-agent: nghttp2/0.7.7

    io:format("Headers: ~p~n", [PList]), %%outputs
%%
%%Headers: [{indexed_header,2},
%%          {indexed_header,4},
%%          {indexed_header,6},
%%          {literal_indexed,1,<<"localhost:8080">>},
%%          {literal_indexed,19,<<"*/*">>},
%%          {indexed_header,16},
%%          {literal_indexed,58,<<"nghttp2/0.7.7">>}]

    ok.
% http://http2.github.io/http2-spec/compression.html#rfc.section.C.2.1
decode_c_2_1_test() ->
    Bin = <<16#40,16#0a,16#63,16#75,16#73,16#74,16#6f,16#6d,16#2d,16#6b,16#65,
            16#79,16#0d,16#63,16#75,16#73,16#74,16#6f,16#6d,16#2d,16#68,16#65,
            16#61,16#64,16#65,16#72>>,
    BinStr = <<"@\ncustom-key\rcustom-header">>,
    ?assertEqual(Bin, BinStr),
    %% 400a 6375 7374 6f6d 2d6b 6579 0d63 7573 | @.custom-key.cus
    %% 746f 6d2d 6865 6164 6572                | tom-header
    ok.

% http://http2.github.io/http2-spec/compression.html#rfc.section.C.2.2
decode_c_2_2_test() ->
    _Bin = <<16#04,16#0c,16#2f,16#73,16#61,16#6d,16#70,16#6c,16#65,
             16#2f,16#70,16#61,16#74,16#68>>,
    %% input| 040c 2f73 616d 706c 652f 7061 7468
    %% out  | :path: /sample/path
    ok.
