-module(hpack).

-export([decode/1]).

-spec decode(binary()) -> term().
decode(Bin) ->
    decode(Bin, []).

-spec decode(binary(), [proplists:property()]) -> [proplists:property()].
%% We're done decoding, return headers
decode(<<>>, HeadersAcc) -> HeadersAcc;
%% First bit is '1', so it's an 'Indexed Header Feild'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.1
decode(<<2#1:1,_/bits>>=B, HeaderAcc) ->
    decode_indexed_header(B, HeaderAcc);
%% First two bits are '01' so it's a 'Literal Header Field with Incremental Indexing'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.2.1
decode(<<2#01:2,_/bits>>=B, HeaderAcc) ->
    decode_literal_header_with_indexing(B, HeaderAcc);
% this is a redundant pattern i think
%decode(<<2#01000000:8,_/bits>>=B, HeaderAcc) ->
%    decode_literal_nonindexed_field(B, HeaderAcc);

%% First four bits are '0000' so it's a 'Literal Header Field without Indexing'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.2.2
decode(<<2#0000:4,_/bits>>=B, HeaderAcc) ->
    decode_literal_header_without_indexing(B, HeaderAcc);

%% First four bits are '0001' so it's a 'Literal Header Field never Indexed'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.2.3
decode(<<2#0001:4,_/bits>>=B, HeaderAcc) ->
    decode_literal_header_never_indexed(B, HeaderAcc);

%% First three bits are '001' so it's a 'Dynamic Table Size Update'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.3
decode(<<2#001:3,_/bits>>=B, HeaderAcc) ->
    %% TODO: This will be annoying because it means passing the HTTP setting
    %% for maximum table size around this entire funtion set
    decode_dynamic_table_size_update(B, HeaderAcc);

%% Oops!
decode(<<B:1,_/binary>>, _HeaderAcc) ->
    lager:debug("Bad header packet ~p", [B]),
    error.

%% this is the easiest!
decode_indexed_header(<<2#1:1,Index:7,B1/bits>>, Acc) ->
    io:format("Index: ~p~n", [Index]),
    decode(B1, Acc ++ [{indexed_header, Index}]).

decode_literal_header_with_indexing(<<2#01:2,Index:6,B1/bits>>, Acc) ->
    {Str, B2} = get_literal(B1),
    case Index of
        0 ->
            {Value, B3} = get_literal(B2),
            decode(B3, Acc ++ [{literal_indexed_new_name, Str, Value}]);
        _ ->
            decode(B2, Acc ++ [{literal_indexed, Index, Str}])
    end.

decode_literal_header_without_indexing(<<2#0000:4,Index:4,B1/bits>>, Acc) ->
    {Str, B2} = get_literal(B1),
    case Index of
        0 ->
            {Value, B3} = get_literal(B2),
            decode(B3, Acc ++ [{literal_wo_index_new_name, Str, Value}]);
        _ ->
            decode(B2, Acc ++ [{literal_wo_index, Index, Str}])
    end.

decode_literal_header_never_indexed(<<2#0001:4,Index:4,B1/bits>>, Acc) ->
    {Str, B2} = get_literal(B1),
    case Index of
        0 ->
            {Value, B3} = get_literal(B2),
            decode(B3, Acc ++ [{literal_wo_index_new_name, Str, Value}]);
        _ ->
            decode(B2, Acc ++ [{literal_wo_index, Index, Str}])
    end.


decode_dynamic_table_size_update(<<2#001:3,_NewSize:5,Bin/bits>>, Acc) ->
    %% Yes, you are reading this right. We're throwing away the new
    %% table size. TODO :D
    decode(Bin, Acc).


get_literal(<<Huff:1,Length:7,Bin/bits>>) ->
    <<RawLiteral:Length/binary,B2/binary>> = Bin,
    Literal = case Huff of
                  1 ->
                      huffman:to_binary(RawLiteral);
                  0 ->
                      RawLiteral
              end,
    {Literal, B2}.
