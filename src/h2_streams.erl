-module(h2_streams).
-include("http2.hrl").
-include("h2_streams.hrl").

-export(
   [
    new/1,
    get/2,
    close/4,
    initiate_stream/7,
    peer_initiated_stream/7,
    replace/2,
    send_what_we_can/4,
    sort/1,
    stream_id/1,
    notify_pid/1,
    update_all_recv_windows/2,
    update_all_send_windows/2,
    update_peer_max_active/2,
    update_self_max_active/2
   ]).

-spec new(
        client | server
       ) -> streams().
new(client) ->
    #streams{type=client};
new(server) ->
    #streams{type=server}.

-spec initiate_stream(
        StreamId :: stream_id(),
        NotifyPid :: pid(),
        CBMod :: module(),
        Socket :: sock:socket(),
        InitialSendWindow :: pos_integer(),
        InitialRecvWindow :: pos_integer(),
        Streams :: streams()
                   ) -> streams()
                      | {error, term()} .
initiate_stream(
  StreamId,
  NotifyPid,
  CBMod,
  Socket,
  InitialSendWindow,
  InitialRecvWindow,
  Streams
 ) ->
    case
        new_stream(
          StreamId,
          NotifyPid,
          CBMod,
          Socket,
          InitialSendWindow,
          InitialRecvWindow,
          Streams#streams.self_initiated) of
        {error, Error} ->
            {error, Error};
        NewStreamSet ->
            Streams#streams{
              self_initiated=NewStreamSet
             }
    end.

-spec peer_initiated_stream(
        StreamId :: stream_id(),
        NotifyPid :: pid(),
        CBMod :: module(),
        Socket :: sock:socket(),
        InitialSendWindow :: pos_integer(),
        InitialRecvWindow :: pos_integer(),
        Streams :: streams()
                   ) -> streams()
                      | {error, term()} .
peer_initiated_stream(
  StreamId,
  NotifyPid,
  CBMod,
  Socket,
  InitialSendWindow,
  InitialRecvWindow,
  Streams
 ) ->
    case
        new_stream(
          StreamId,
          NotifyPid,
          CBMod,
          Socket,
          InitialSendWindow,
          InitialRecvWindow,
          Streams#streams.peer_initiated) of
        {error, Error} ->
            {error, Error};
        NewStreamSet ->
            Streams#streams{
              peer_initiated=NewStreamSet
             }
    end.

new_stream(
  StreamId,
  NotifyPid,
  CBMod,
  Socket,
  InitialSendWindow,
  InitialRecvWindow,
  StreamSet=#stream_set{max_active=unlimited}
 ) ->
    new_stream_(StreamId, NotifyPid, CBMod, Socket, InitialSendWindow, InitialRecvWindow, StreamSet);
new_stream(
  _StreamId,
  _NotifyPid,
  _CBMod,
  _Socket,
  _InitialSendWindow,
  _InitialRecvWindow,
  _StreamSet=#stream_set{max_active=Max, active_count=Active}
 )
  when Active >= Max ->
            {error, too_many_active_streams};
new_stream(
  StreamId,
  NotifyPid,
  CBMod,
  Socket,
  InitialSendWindow,
  InitialRecvWindow,
  StreamSet
 ) ->
    new_stream_(StreamId, NotifyPid, CBMod, Socket, InitialSendWindow, InitialRecvWindow, StreamSet).

new_stream_(
  StreamId,
  NotifyPid,
  CBMod,
  Socket,
  InitialSendWindow,
  InitialRecvWindow,
  StreamSet
 ) ->
    {ok, Pid} = http2_stream:start_link(
                   StreamId,
                   self(),
                   CBMod,
                   Socket
                  ),
    NewStream = #active_stream{
                   id = StreamId,
                   pid = Pid,
                   notify_pid=NotifyPid,
                   send_window_size=InitialSendWindow,
                   recv_window_size=InitialRecvWindow
                  },
    lager:debug("NewStream ~p", [NewStream]),
    StreamSet#stream_set{
      active_count = StreamSet#stream_set.active_count + 1,
      active = [NewStream|StreamSet#stream_set.active]
     }.

-spec get(Id :: stream_id(),
          Streams :: streams()) ->
                 stream() | false.
get(Id, #streams{type=client}=Streams)
  when Id rem 2 =:= 0 ->
    get_set(Id, Streams#streams.peer_initiated);
get(Id, #streams{type=client}=Streams)
  when Id rem 2 =:= 1 ->
    get_set(Id, Streams#streams.self_initiated);
get(Id, #streams{type=server}=Streams)
  when Id rem 2 =:= 0 ->
    get_set(Id, Streams#streams.self_initiated);
get(Id, #streams{type=server}=Streams)
  when Id rem 2 =:= 1 ->
    get_set(Id, Streams#streams.peer_initiated).

get_set(Id, StreamSet) ->
    lists:keyfind(Id, 2, StreamSet#stream_set.active).

close(Closed=#closed_stream{},
      _Headers,
      _Body,
      Streams) ->
    {Closed, Streams};
close(_Idle=#idle_stream{id=StreamId},
      Headers, Body,
      Streams) ->
    Closed = #closed_stream{
                id=StreamId,
                response_headers=Headers,
                response_body=Body
               },
    {Closed, replace(Closed, Streams)};
close(#active_stream{
         id=Id,
         notify_pid=NotifyPid
        },
      Headers,
      Body,
      Streams) ->
    Closed = #closed_stream{
                id=Id,
                response_headers=Headers,
                response_body=Body,
                notify_pid=NotifyPid
               },
    {Closed, replace(Closed, Streams)}.

stream_id(false) ->
    undefined;
stream_id(#idle_stream{id=SID}) ->
    SID;
stream_id(#active_stream{id=SID}) ->
    SID;
stream_id(#closed_stream{id=SID}) ->
    SID.

type(#idle_stream{}) ->
    idle_stream;
type(#active_stream{}) ->
    active_stream;
type(#closed_stream{}) ->
    closed_stream.

%% the false clause is here as an artifact of us using a simple
%% lists:keyfind
notify_pid(false) -> undefined;
notify_pid(#idle_stream{}) ->
    undefined;
notify_pid(#active_stream{notify_pid=Pid}) ->
    Pid;
notify_pid(#closed_stream{notify_pid=Pid}) ->
    Pid.

-spec replace(Stream :: stream(),
              Streams :: streams()) ->
                     streams().
replace(Stream, Streams) ->
    StreamId = stream_id(Stream),
    WhichSet =
        case {StreamId rem 2, Streams#streams.type} of
            {0, client} ->
                #streams.peer_initiated;
            {1, client} ->
                #streams.self_initiated;
            {0, server} ->
                #streams.self_initiated;
            {1, server} ->
                #streams.peer_initiated
        end,

    StreamSet = element(WhichSet, Streams),
    NewSet = replace_set(StreamId, Stream, StreamSet),

    case WhichSet of
        #streams.peer_initiated ->
            Streams#streams{
              peer_initiated=NewSet
             };
        #streams.self_initiated ->
            Streams#streams{
              self_initiated=NewSet
             }
    end.

replace_set(StreamId, Stream, StreamSet) ->
    OldStream = lists:keyfind(StreamId, 2, StreamSet#stream_set.active),
    OldType = type(OldStream),
    NewType = type(Stream),

    NewSet =
        StreamSet#stream_set{
          active = lists:keyreplace(StreamId, 2, StreamSet#stream_set.active, Stream)
         },

    case {OldType, NewType} of
        {active_stream, active_stream} ->
            NewSet;
        {active_stream, closed_stream} ->
            NewSet#stream_set{
              active_count=StreamSet#stream_set.active_count-1
             };
        {_, _} ->
            NewSet
    end.

%% TODO: Change sort to send peer_initiated first!
-spec sort(Streams::streams()) -> streams().
sort(Streams) ->
    Streams#streams{
      peer_initiated = sort_set(Streams#streams.peer_initiated),
      self_initiated = sort_set(Streams#streams.self_initiated)
     }.

sort_set(StreamSet) ->
    StreamSet#stream_set{
      active=lists:keysort(2, StreamSet#stream_set.active)
     }.

-spec update_all_recv_windows(Delta :: integer(),
                              Streams:: streams()) ->
                                     streams().
update_all_recv_windows(Delta, Streams) ->
    Streams#streams{
      peer_initiated=update_all_recv_windows_set(Delta, Streams#streams.peer_initiated),
      self_initiated=update_all_recv_windows_set(Delta, Streams#streams.self_initiated)
     }.

update_all_recv_windows_set(Delta, StreamSet) ->
    NewActive = lists:map(
                  fun(#active_stream{}=S) ->
                          S#active_stream{
                            recv_window_size=S#active_stream.recv_window_size+Delta
                           };
                     (S) -> S
                  end,
                  StreamSet#stream_set.active),
    StreamSet#stream_set{
      active=NewActive
     }.

-spec update_all_send_windows(Delta :: integer(),
                              Streams:: streams()) ->
                                     streams().
update_all_send_windows(Delta, Streams) ->
    Streams#streams{
      peer_initiated=update_all_send_windows_set(Delta, Streams#streams.peer_initiated),
      self_initiated=update_all_recv_windows_set(Delta, Streams#streams.self_initiated)
     }.

update_all_send_windows_set(Delta, StreamSet) ->
    NewActive = lists:map(
                  fun(#active_stream{}=S) ->
                          S#active_stream{
                            send_window_size=S#active_stream.send_window_size+Delta
                           };
                     (S) -> S
                  end,
                  StreamSet#stream_set.active),
    StreamSet#stream_set{
      active=NewActive
     }.

-spec update_peer_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: streams()) ->
                                    streams().
update_peer_max_active(NewMax,
                       #streams{
                          peer_initiated=PI
                         }=Streams) ->
    Streams#streams{
      peer_initiated=PI#stream_set{max_active=NewMax}
     }.

-spec update_self_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: streams()) ->
                                    streams().
update_self_max_active(NewMax,
                       #streams{
                          self_initiated=SI
                         }=Streams) ->
    Streams#streams{
      self_initiated=SI#stream_set{max_active=NewMax}
     }.

-spec send_what_we_can(StreamId :: all | stream_id(),
                       ConnSendWindowSize :: integer(),
                       MaxFrameSize :: non_neg_integer(),
                       Streams :: streams()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: streams()}.
send_what_we_can(all, ConnSendWindowSize, MaxFrameSize, Streams) ->
    {AfterPeerWindowSize,
     NewPeerInitiated} = c_send_what_we_can(
                           ConnSendWindowSize,
                           MaxFrameSize,
                           Streams#streams.peer_initiated#stream_set.active,
                           []),
    {AfterAfterWindowSize,
     NewSelfInitiated} = c_send_what_we_can(
                           AfterPeerWindowSize,
                           MaxFrameSize,
                           Streams#streams.self_initiated#stream_set.active,
                           []),

    {AfterAfterWindowSize,
     Streams#streams{
       peer_initiated=Streams#streams.peer_initiated#stream_set{active=NewPeerInitiated},
       self_initiated=Streams#streams.self_initiated#stream_set{active=NewSelfInitiated}
      }
    };
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
                                {integer(), [stream()]}.
%% If we hit =< 0, done
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
s_send_what_we_can(SWS, MFS, #active_stream{}=Stream) ->
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
    end;
s_send_what_we_can(SWS, _MFS, NonActiveStream) ->
    {SWS, NonActiveStream}.

-ifdef(TEST).
-compile([export_all]).
basic_streams_structure_test() ->
    %% Constructor:
    _Streams = new(client), %% There will be more to this


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
