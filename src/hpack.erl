-module(hpack).

-export([
    decode/2,
    new_decode_context/0,
    encode/2,
    new_encode_context/0
    ]).

-type header() :: {atom(), binary()}.
-type headers():: [header()].

-export_type([headers/0,header/0]).

-compile(export_all).

-record(decode_context, {
        dynamic_table = headers:new()
    }).
-type decode_context() :: #decode_context{}.

-record(encode_context, {
        dynamic_table = headers:new()
    }).
-type encode_context() :: #encode_context{}.

-spec new_encode_context() -> encode_context().
new_encode_context() -> #encode_context{}.

-spec new_decode_context() -> decode_context().
new_decode_context() -> #decode_context{}.

-spec encode([{binary(), binary()}], encode_context()) -> {binary(), encode_context()}.
encode(Headers, Context) ->
    encode(Headers, <<>>, Context).

-spec decode(binary(), decode_context()) -> {headers(), decode_context()}.
decode(Bin, Context) ->
    decode(Bin, [], Context).

-spec decode(binary(), headers(), decode_context()) -> {headers(), decode_context()}.
%% We're done decoding, return headers
decode(<<>>, HeadersAcc, C) -> {HeadersAcc, C};
%% First bit is '1', so it's an 'Indexed Header Feild'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.1
decode(<<2#1:1,_/bits>>=B, HeaderAcc, Context) ->
    decode_indexed_header(B, HeaderAcc, Context);
%% First two bits are '01' so it's a 'Literal Header Field with Incremental Indexing'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.2.1
decode(<<2#01:2,_/bits>>=B, HeaderAcc, Context) ->
    decode_literal_header_with_indexing(B, HeaderAcc, Context);

%% First four bits are '0000' so it's a 'Literal Header Field without Indexing'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.2.2
decode(<<2#0000:4,_/bits>>=B, HeaderAcc, Context) ->
    decode_literal_header_without_indexing(B, HeaderAcc, Context);

%% First four bits are '0001' so it's a 'Literal Header Field never Indexed'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.2.3
decode(<<2#0001:4,_/bits>>=B, HeaderAcc, Context) ->
    decode_literal_header_never_indexed(B, HeaderAcc, Context);

%% First three bits are '001' so it's a 'Dynamic Table Size Update'
%% http://http2.github.io/http2-spec/compression.html#rfc.section.6.3
decode(<<2#001:3,_/bits>>=B, HeaderAcc, Context) ->
    %% TODO: This will be annoying because it means passing the HTTP setting
    %% for maximum table size around this entire funtion set
    decode_dynamic_table_size_update(B, HeaderAcc, Context);

%% Oops!
decode(<<B:1,_/binary>>, _HeaderAcc, _Context) ->
    lager:debug("Bad header packet ~p", [B]),
    error.

decode_indexed_header(<<2#1:1,2#1111111:7,B1/bits>>,
                      Acc,
                      Context = #decode_context{dynamic_table=T}) ->
    {Index, B2} = decode_integer(B1, 7),
    decode(B2, Acc ++ [headers:lookup(Index, T)], Context);
decode_indexed_header(<<2#1:1,Index:7,B1/bits>>,
                      Acc,
                      Context = #decode_context{dynamic_table=T}) ->
    decode(B1, Acc ++ [headers:lookup(Index, T)], Context).

%% This is the case when the index is greater than 62
decode_literal_header_with_indexing(<<2#01:2,2#111111:6,B1/bits>>, Acc,
    Context = #decode_context{dynamic_table=T}) ->
    {Index, Rem} = decode_integer(B1,6),
    {Str, B2} = get_literal(Rem),
    {Name,_} = case headers:lookup(Index, T) of
        undefined ->
            lager:error("Tried to find ~p in ~p", [Index, T]),
            throw(undefined);
        {N, V} -> {N, V}
    end,
    decode(B2,
           Acc ++ [{Name, Str}],
           Context#decode_context{dynamic_table=headers:add(Name, Str, T)});
decode_literal_header_with_indexing(<<2#01:2,2#000000:6,B1/bits>>, Acc,
    Context = #decode_context{dynamic_table=T}) ->
    {Str, B2} = get_literal(B1),
    {Value, B3} = get_literal(B2),
    decode(B3,
           Acc ++ [{Str, Value}],
           Context#decode_context{dynamic_table=headers:add(Str, Value, T)});
decode_literal_header_with_indexing(<<2#01:2,Index:6,B1/bits>>, Acc,
    Context = #decode_context{dynamic_table=T}) ->
    {Str, B2} = get_literal(B1),
    {Name,_}= headers:lookup(Index, T),
    decode(B2,
           Acc ++ [{Name, Str}],
           Context#decode_context{dynamic_table=headers:add(Name, Str, T)}).

decode_literal_header_without_indexing(<<2#0000:4,2#1111:4,B1/bits>>, Acc,
    Context = #decode_context{dynamic_table=T}) ->
    {Index, Rem} = decode_integer(B1,4),
    {Str, B2} = get_literal(Rem),
    {Name,_}= headers:lookup(Index, T),
    decode(B2, Acc ++ [{Name, Str}], Context);
decode_literal_header_without_indexing(<<2#0000:4,2#0000:4,B1/bits>>, Acc,
    Context) ->
    {Str, B2} = get_literal(B1),
    {Value, B3} = get_literal(B2),
    decode(B3, Acc ++ [{Str, Value}], Context);
decode_literal_header_without_indexing(<<2#0000:4,Index:4,B1/bits>>, Acc,
    Context = #decode_context{dynamic_table=T}) ->
    {Str, B2} = get_literal(B1),
    {Name,_}= headers:lookup(Index, T),
    decode(B2, Acc ++ [{Name, Str}], Context).

decode_literal_header_never_indexed(<<2#0001:4,2#1111:4,B1/bits>>, Acc,
    Context = #decode_context{dynamic_table=T}) ->
    {Index, Rem} = decode_integer(B1,4),
    {Str, B2} = get_literal(Rem),
    {Name,_}= headers:lookup(Index, T),
    decode(B2, Acc ++ [{Name, Str}], Context);
decode_literal_header_never_indexed(<<2#0001:4,2#0000:4,B1/bits>>, Acc,
    Context) ->
    {Str, B2} = get_literal(B1),
    {Value, B3} = get_literal(B2),
    decode(B3, Acc ++ [{Str, Value}], Context);
decode_literal_header_never_indexed(<<2#0001:4,Index:4,B1/bits>>, Acc,
    Context = #decode_context{dynamic_table=T}) ->
    {Str, B2} = get_literal(B1),
    {Name,_}= headers:lookup(Index, T),
    decode(B2, Acc ++ [{Name, Str}], Context).

decode_dynamic_table_size_update(<<2#001:3,2#11111:5,Bin/binary>>, Acc, Context) ->
    {NewSize, Rem} = decode_integer(Bin,5),
    decode(Rem, Acc, headers:resize(NewSize, Context));
decode_dynamic_table_size_update(<<2#001:3,NewSize:5,Bin/binary>>, Acc, Context) ->
    decode(Bin, Acc, headers:resize(NewSize, Context)).

get_literal(<<>>) ->
    {<<>>, <<>>};
get_literal(<<Huff:1,Length:7,Bin/binary>>) ->
    <<RawLiteral:Length/binary,B2/binary>> = Bin,
    Literal = case Huff of
                  1 ->
                      huffman:decode(RawLiteral);
                  0 ->
                      RawLiteral
              end,
    {Literal, B2}.


%  0   1   2   3   4   5   6   7
%+---+---+---+---+---+---+---+---+
%| X | X | X | 1 | 1 | 1 | 1 | 1 |  Prefix = 31, I = 1306
%| 1 | 0 | 0 | 1 | 1 | 0 | 1 | 0 |  1306>=128, encode(154), I=1306/128
%| 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0 |  10<128, encode(10), done
%+---+---+---+---+---+---+---+---+

decode_integer(Bin, Prefix) ->
    I = 1 bsl Prefix - 1,
    {I2, Rem} = decode_integer(Bin, 0, 0),
    {I+I2, Rem}.

decode_integer(<<1:1,Int:7,Rem/binary>>, M, I) ->
    decode_integer(Rem, M+1, I + Int * math:pow(2, M));
decode_integer(<<0:1,Int:7,Rem/binary>>, M, I) ->
    {round(I + Int * math:pow(2, M)), Rem}.

%% SO MANY ENCODING TODOs
%% No huffman on the encoding side
%% no non-indexed field encoding
%% serious refactor needed

encode_integer(Int, Prefix) ->
    PrefixMask = 1 bsl Prefix - 1,
    Remaining = Int - PrefixMask,
    case {Remaining < 0, Int =:= PrefixMask} of
        {_, true} ->
            <<Int:Prefix,0:8>>;
        {true, false} ->
            <<Int:Prefix>>;
        _ ->
            Bin = encode_integer_(Remaining, <<>>),
            <<PrefixMask:Prefix, Bin/binary>>
    end.

encode_integer_(0, BinAcc) ->
    BinAcc;
encode_integer_(I, BinAcc) ->
    Rem = I bsr 7,
    This = (I rem 128),
    ThisByte = case Rem =:= 0 of
        true ->
            This;
        _ ->
            128 + This
    end,
    encode_integer_(Rem, <<BinAcc/binary, ThisByte>>).

-spec encode([{binary(), binary()}], binary(), encode_context()) -> {binary(), encode_context()}.
encode([], Acc, Context) ->
    {Acc, Context};
encode([{HeaderName, HeaderValue}|Tail], B, Context = #encode_context{dynamic_table=T}) ->
    {BinToAdd, NewContext} = case headers:match({HeaderName, HeaderValue}, T) of
        {indexed, I} ->
            {encode_indexed(I), Context};
        {literal_with_indexing, I} ->
            {encode_literal_indexed(I, HeaderValue),
             Context#encode_context{dynamic_table=headers:add(HeaderName, HeaderValue, T)}};
        {literal_wo_indexing, _X} ->
            {encode_literal_wo_index(HeaderName, HeaderValue),
             Context#encode_context{dynamic_table=headers:add(HeaderName, HeaderValue, T)}}
    end,
    NewB = <<B/binary,BinToAdd/binary>>,

    %NewB = try <<B/binary,BinToAdd/binary>> of
    %    B4 -> B4
    %catch
    %    _:_ ->
    %        lager:error("BinToAdd ~p", [BinToAdd])
    %end,

    encode(Tail, NewB, NewContext).

encode_indexed(I) when I < 63 ->
    <<2#1:1,I:7>>;
encode_indexed(I) ->
    Encoded = encode_integer(I, 7),
    <<2#1:1, Encoded/bits>>.

encode_literal_indexed(I, Value) when I < 63 ->
    BinToAdd = encode_literal(Value),
    <<2#01:2,I:6,BinToAdd/binary>>;
encode_literal_indexed(I, Value) ->
    Index = encode_integer(I, 6),
    BinToAdd = encode_literal(Value),
    <<2#01:2,Index/bits,BinToAdd/binary>>.

encode_literal(Value) ->
    L = size(Value),
    case L < 127 of
        true ->
            <<2#0:1,L:7,Value/binary>>;
        false ->
            {_,BigL} = encode_integer(L, 7),
            <<127:8,BigL/binary,Value/binary>>
    end.

encode_literal_wo_index(Name, Value) ->
    EncName = encode_literal(Name),
    EncValue = encode_literal(Value),
    <<2#01000000,EncName/binary,EncValue/binary>>.
