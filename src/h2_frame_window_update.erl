-module(h2_frame_window_update).
-include("http2.hrl").
-behaviour(h2_frame).

-export(
   [
    new/1,
    format/1,
    read_binary/2,
    send/3,
    size_increment/1,
    to_binary/1
   ]).

-record(window_update, {
          window_size_increment :: non_neg_integer()
         }).
-type payload() :: #window_update{}.
-type frame() :: {h2_frame:header(), payload()}.
-export_type([payload/0, frame/0]).

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[Window Update: ~p]", [Payload]).

-spec new(non_neg_integer()) -> payload().
new(Increment) ->
    #window_update{window_size_increment=Increment}.


-spec read_binary(Bin::binary(),
                  Header::h2_frame:header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(_,
            #frame_header{
               length=L
               })
  when L =/= 4 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
read_binary(<<_R:1,0:31,Rem/bits>>, FH) ->
    {error, FH#frame_header.stream_id, ?PROTOCOL_ERROR, Rem};
read_binary(Bin, #frame_header{length=4}) ->
    <<_R:1,Increment:31,Rem/bits>> = Bin,
    Payload = #window_update{
                 window_size_increment=Increment
                },
    {ok, Payload, Rem};
read_binary(_, #frame_header{}=H) ->
    %TODO: Maybe return some Rem in element(4) once we know what that
    %is
    {error, H#frame_header.stream_id, ?FRAME_SIZE_ERROR, <<>>}.

-spec send(sock:socket(),
           non_neg_integer(),
           stream_id()) ->
                  ok.
send(Socket, WindowSizeIncrement, StreamId) ->
    sock:send(Socket, [
                       <<4:24,?WINDOW_UPDATE:8,0:8,0:1,StreamId:31>>,
                       <<0:1,WindowSizeIncrement:31>>]).


-spec size_increment(payload()) -> non_neg_integer().
size_increment(#window_update{window_size_increment=WSI}) ->
    WSI.

-spec to_binary(payload()) -> iodata().
to_binary(#window_update{
        window_size_increment=I
    }) ->
    <<0:1,I:31>>.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

read_binary_zero_test() ->
    ?assertEqual({error, 0, ?PROTOCOL_ERROR, <<>>},
                 read_binary(<<0:1,0:31>>, #frame_header{stream_id=0,length=4})),
    ?assertEqual({error, 2, ?PROTOCOL_ERROR, <<>>},
                 read_binary(<<1:1,0:31>>, #frame_header{stream_id=2,length=4})),
    ok.

-endif.
