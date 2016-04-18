-module(h2_streams).
-include("http2.hrl").
-include("h2_streams.hrl").

-export(
   [
    active_stream_count/1,
    new/0,
    get/2,
    insert/2,
    replace/2,
    send_what_we_can/4,
    sort/1,
    update_all_recv_windows/2,
    update_all_send_windows/2
   ]).

-spec new() -> streams().
new() ->
    [].

-spec get(Id :: stream_id(),
          Streams :: streams()) ->
                 stream() | false.
get(Id, Streams) ->
    lists:keyfind(Id, 2, Streams).

-spec insert(Stream :: stream(),
             Streams :: streams()) ->
                    streams().
insert(Stream, Streams) ->
    [Stream|Streams].

-spec replace(Stream :: stream(),
              Streams :: streams()) ->
                     streams().
replace(Stream, Streams) ->
    StreamId = element(2, Stream),
    lists:keyreplace(StreamId, 2, Streams, Stream).

-spec sort(Streams::streams()) -> streams().
sort(Streams) ->
    lists:keysort(2, Streams).

-spec active_stream_count(streams()) -> non_neg_integer().
active_stream_count(Streams) ->
    lists:foldl(
      fun(#active_stream{pid=undefined}, Acc) ->
              Acc;
         (_, Acc) ->
              Acc + 1
      end,
      0,
      Streams).

-spec update_all_recv_windows(Delta :: integer(),
                              Streams:: streams()) ->
                                     streams().
update_all_recv_windows(Delta, Streams) ->
    [ S#active_stream{
        recv_window_size=S#active_stream.recv_window_size+Delta
       }
      || S <- Streams].

-spec update_all_send_windows(Delta :: integer(),
                              Streams:: streams()) ->
                                     streams().
update_all_send_windows(Delta, Streams) ->
    [ S#active_stream{
        send_window_size=S#active_stream.send_window_size+Delta
       }
      || S <- Streams].


-spec send_what_we_can(StreamId :: stream_id() | 'all',
                       ConnSendWindowSize :: integer(),
                       MaxFrameSize :: non_neg_integer(),
                       Streams :: streams()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: streams()}.
send_what_we_can(all, ConnSendWindowSize, MaxFrameSize, Streams) ->
    %% once Streams isn't a list(stream()) anymore, we'll need to pull
    %% a list out here, and pass it down. That's why the specs below
    %% say [stream()] and not streams()
    c_send_what_we_can(ConnSendWindowSize, MaxFrameSize, Streams, []);
send_what_we_can(StreamId, ConnSendWindowSize, MaxFrameSize, Streams) ->
    {NewConnSendWindowSize, NewStream} =
        s_send_what_we_can(ConnSendWindowSize,
                           MaxFrameSize,
                           get(StreamId, Streams)),
    {NewConnSendWindowSize,
     replace(NewStream, Streams)}.

%% Send at the connection level
-spec c_send_what_we_can(ConnSendWindowSize :: integer(),
                         MaxFrameSize :: non_neg_integer(),
                         Streams :: [stream()],
                         Acc :: [stream()]
                        ) ->
                                {non_neg_integer(), streams()}.
%% If we hit 0, done
c_send_what_we_can(ConnSendWindowSize, _MFS, Streams, Acc)
  when ConnSendWindowSize =< 0 ->
    {ConnSendWindowSize, lists:reverse(Acc) ++ Streams};
%% If we hit end of streams list, done
c_send_what_we_can(SWS, _MFS, [], Acc) ->
    {SWS, lists:reverse(Acc)};
%% Otherwise, try sending on the working stream
c_send_what_we_can(SWS, MFS, [S|Streams], Acc) ->
    {NewSWS, NewS} = s_send_what_we_can(SWS, MFS, S),
    c_send_what_we_can(NewSWS, MFS, Streams, [NewS|Acc]).

%% Send at the stream level
-spec s_send_what_we_can(SWS :: integer(),
                         MFS :: non_neg_integer(),
                         Stream :: stream()) ->
                                {integer(), stream()}.
s_send_what_we_can(SWS, _, #active_stream{queued_data=Data}=S)
  when is_atom(Data) ->
    {SWS, S};
s_send_what_we_can(SWS, MFS, Stream) ->
    %% We're coming in here with three numbers we need to look at:
    %% * Connection send window size
    %% * Stream send window size
    %% * Maximimum frame size

    %% If none of them are zero, we have to send something, so we're
    %% going to figure out what's the biggest number we can send. If
    %% that's more than we have to send, we'll send everything and put
    %% an END_STREAM flag on it. Otherwise, we'll send as much as we
    %% can. Then, based on which number was the limiting factor, we'll
    %% make another decision

    %% If it was MAX_FRAME_SIZE, then we recurse into this same
    %% function, because we're able to send another frame of some
    %% length.

    %% If it was connection send window size, we're blocked at the
    %% connection level and we should break out of this recursion

    %% If it was stream send_window size, we're blocked on this
    %% stream, but other streams can still go, so we'll break out of
    %% this recursion, but not the connection level

    SSWS = Stream#active_stream.send_window_size,

    QueueSize = byte_size(Stream#active_stream.queued_data),

    {MaxToSend, ExitStrategy} =
        case {MFS =< SWS andalso MFS =< SSWS, SWS < SSWS} of
            %% If MAX_FRAME_SIZE is the smallest, send one and recurse
            {true, _} ->
                {MFS, max_frame_size};
            {false, true} ->
                {SWS, connection};
            _ ->
                {SSWS, stream}
        end,

    {Frame, SentBytes, NewS} =
        case MaxToSend > QueueSize of
            true ->
                Flags = case Stream#active_stream.body_complete of
                         true -> ?FLAG_END_STREAM;
                         false -> 0
                        end,
                %% We have the power to send everything
                {{#frame_header{
                     stream_id=Stream#active_stream.id,
                     flags=Flags,
                     type=?DATA,
                     length=QueueSize
                    },
                  http2_frame_data:new(Stream#active_stream.queued_data)}, %% Full Body
                 QueueSize,
                 Stream#active_stream{
                   queued_data=done,
                   send_window_size=SSWS-QueueSize}};
            false ->
                <<BinToSend:MaxToSend/binary,Rest/binary>> = Stream#active_stream.queued_data,
                {{#frame_header{
                     stream_id=Stream#active_stream.id,
                     type=?DATA,
                     length=MaxToSend
                    },
                  http2_frame_data:new(BinToSend)},
                 MaxToSend,
                 Stream#active_stream{
                   queued_data=Rest,
                   send_window_size=SSWS-MaxToSend}}
        end,

    _Sent = http2_stream:send_frame(Stream#active_stream.pid, Frame),

    case ExitStrategy of
        max_frame_size ->
            s_send_what_we_can(SWS - SentBytes, MFS, NewS);
        stream ->
            {SWS - SentBytes, NewS};
        connection ->
            {0, NewS}
    end.




-ifdef(TEST).
-compile([export_all]).
basic_streams_structure_test() ->
    %% Constructor:
    _Streams = new(), %% There will be more to this


    %% When we start, all streams are idle
    %% {idle_stream, 1} = get(1, Streams).
    %% {idle_stream, 2147483647} = get(2147483647, Streams).

    %% Streams1 = activate(1, Streams).
    %% {active_stream, 1, etc...} = get(1, Streams1).
    %% {idle_stream, 3} = get(3, Streams1).
    %% {idle_stream, 2147483647} = get(2147483647, Streams1).

    %% Let's activate 5 now, 3 should be closed
    %% Streams2 = activate(5, Streams1).
    %% {active_stream, 1, etc...} = get(1, Streams2).
    %% {closed_stream, 3} = get(3, Streams2).
    %% {active_stream, 5, etc...} = get(5, Streams2).
    %% {idle_stream, 7} = get(7, Streams2).
    %% {idle_stream, 2147483647} = get(2147483647, Streams2).

    %% Let's activate 9 too
    %% Streams3 = activate(9, Streams2).
    %% {active_stream, 1, etc...} = get(1, Streams3).
    %% {closed_stream, 3} = get(3, Streams3).
    %% {active_stream, 5, etc...} = get(5, Streams3).
    %% {closed_stream, 7} = get(7, Streams3).
    %% {active_stream, 9, etc...} = get(9, Streams3).
    %% Now we have three active streams and 2 closed ones.
    %% {idle_stream, 11} = get(11, Streams3).

    %% Streams4 = close(9, Streams3).
    %% {active_stream, 1, etc...} = get(1, Streams3).
    %% {closed_stream, 3} = get(3, Streams3).
    %% {active_stream, 5, etc...} = get(5, Streams3).
    %% {closed_stream, 7} = get(7, Streams3).
    %% {active_stream, 9, etc...} = get(9, Streams3).
    %% Now we have three active streams and 2 closed ones.
    %% {idle_stream, 11} = get(11, Streams3).
    ok.

-endif.
