-module(h2_stream_set).
-include("http2.hrl").

%% This module exists to manage a set of all streams for a given
%% connection. When a connection starts, a stream set logically
%% contains streams from id 1 to 2^31-1. In practicality, storing that
%% many idle streams in a collection of any type would be more memory
%% intensive. We're going to manage that here in this module, but to
%% the outside, it will behave as if they all exist

-record(
   stream_set,
   {
     %% Type determines which streams are mine, and which are theirs
     type :: client | server,
     %% Streams initiated by this peer
     mine :: peer_subset(),
     %% Streams initiated by the other peer
     theirs :: peer_subset()
   }).
-type stream_set() :: #stream_set{}.
-export_type([stream_set/0]).

%% The stream_set needs to keep track of two subsets of streams, one
%% for the streams that it has initiated, and one for the streams that
%% have been initiated on the other side of the connection. It is this
%% peer_subset that will try to optimize the set of stream metadata
%% that we're storing in memory. For each side of the connection, we
%% also need an accurate count of how many are currently active

-record(
   peer_subset,
   {
     %% Provided by the connection settings, we can check against this
     %% every time we try to add a stream to this subset
     max_active = unlimited :: unlimited | pos_integer(),
     %% A counter that's an accurate reflection of the number of
     %% active streams
     active_count = 0 :: non_neg_integer(),

     %% lowest_stream_id is the lowest stream id that we're currently
     %% managing in memory. Any stream with an id lower than this is
     %% automatically of type closed.
     lowest_stream_id = 0 :: stream_id(),

     %% Next available stream id will be the stream id of the next
     %% stream that can be added to this subset. That means if asked
     %% for a stream with this id or higher, the stream type returned
     %% must be idle. Any stream id lower than this that isn't active
     %% must be of type closed.
     next_available_stream_id :: stream_id(),

     %% A bit of a misnomer, active is actually the set of streams
     %% that are active in MEMORY not the connection. This will
     %% include *ALL* active streams, and possibly some closed streams
     %% as well that have yet to be garbage collected.
     active = [] :: [stream()]
   }).
-type peer_subset() :: #peer_subset{}.


%% Streams all have stream_ids. It is the only thing all three types
%% have. It *MUST* be the first field in *ALL* *_stream{} records.

%% The metadata for an active stream is, unsurprisingly, the most
%% complex.
-record(
   active_stream, {
     id                    :: stream_id(),
     % Pid running the http2_stream gen_statem
     pid                   :: pid(),
     % The process to notify with events on this stream
     notify_pid            :: pid() | undefined,
     % The stream's flow control send window size
     send_window_size      :: non_neg_integer(),
     % The stream's flow control recv window size
     recv_window_size      :: non_neg_integer(),
     % Data that is in queue to send on this stream, if flow control
     % hasn't allowed it to be sent yet
     queued_data           :: undefined | done | binary(),
     % Has the body been completely recieved.
     body_complete = false :: boolean(),
     trailers = undefined  :: [h2_frame:frame()] | undefined
    }).
-type active_stream() :: #active_stream{}.

%% The closed_stream record is way more important to a client than a
%% server. It's a way of holding on to a response that has been
%% recieved, but not processed by the client yet.
-record(
   closed_stream, {
     id               :: stream_id(),
     % The pid to notify about events on this stream
     notify_pid       :: pid() | undefined,
     % The response headers received
     response_headers :: hpack:headers() | undefined,
     % The response body
     response_body    :: binary() | undefined,
     % The response trailers received
     response_trailers :: hpack:headers() | undefined,
     % Can this be thrown away?
     garbage = false  :: boolean() | undefined
     }).
-type closed_stream() :: #closed_stream{}.

%% An idle stream record isn't used for much. It's never stored,
%% unlike the other two types. It is always generated on the fly when
%% asked for a stream >= next_available_stream_id. But, we're able to
%% perform a rst_stream operation on it, and we need a stream_id to
%% make that happen.
-record(
   idle_stream, {
     id :: stream_id()
    }).
-type idle_stream() :: #idle_stream{}.

%% So a stream can be any of these things. And it will be something
%% that you can pass back into serveral functions here in this module.
-type stream() :: active_stream()
                | closed_stream()
                | idle_stream().
-export_type([stream/0]).

%% Set Operations
-export(
   [
    new/1,
    new_stream/9,
    get/2,
    upsert/2,
    sort/1
   ]).

%% Accessors
-export(
   [
    queued_data/1,
    update_trailers/2,
    update_data_queue/3,
    decrement_recv_window/2,
    recv_window_size/1,
    response/1,
    send_window_size/1,
    increment_send_window_size/2,
    pid/1,
    stream_id/1,
    stream_pid/1,
    notify_pid/1,
    type/1,
    my_active_count/1,
    their_active_count/1,
    my_active_streams/1,
    their_active_streams/1,
    my_max_active/1,
    their_max_active/1
   ]
  ).

-export(
   [
    close/3,
    send_what_we_can/4,
    update_all_recv_windows/2,
    update_all_send_windows/2,
    update_their_max_active/2,
    update_my_max_active/2
   ]
  ).

%% new/1 returns a new stream_set. This is your constructor.
-spec new(
        client | server
       ) -> stream_set().
new(client) ->
    #stream_set{
       type=client,
       %% I'm a client, so mine are always odd numbered
       mine=
           #peer_subset{
              lowest_stream_id=0,
              next_available_stream_id=1
             },
       %% And theirs are always even
       theirs=
           #peer_subset{
              lowest_stream_id=0,
              next_available_stream_id=2
             }
      };
new(server) ->
    #stream_set{
       type=server,
       %% I'm a server, so mine are always even
       mine=
           #peer_subset{
              lowest_stream_id=0,
              next_available_stream_id=2
             },
       %% And theirs are always odd.
       theirs=
           #peer_subset{
              lowest_stream_id=0,
              next_available_stream_id=1
             }
      }.

-spec new_stream(
        StreamId :: stream_id(),
        NotifyPid :: pid(),
        CBMod :: module(),
        CBOpts :: list(),
        Socket :: sock:socket(),
        InitialSendWindow :: integer(),
        InitialRecvWindow :: integer(),
        Type :: client | server,
        StreamSet :: stream_set()) ->
                        {pid(), stream_set()}
                            | {error, error_code(), closed_stream()}.
new_stream(
          StreamId,
          NotifyPid,
          CBMod,
          CBOpts,
          Socket,
          InitialSendWindow,
          InitialRecvWindow,
          Type,
          StreamSet) ->
    PeerSubset = get_peer_subset(StreamId, StreamSet),
    case PeerSubset#peer_subset.max_active =/= unlimited andalso
         PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active
    of
        true ->
            {error, ?REFUSED_STREAM, #closed_stream{id=StreamId}};
        false ->
            {ok, Pid} = h2_stream:start_link(
                       StreamId,
                       self(),
                       CBMod,
                       CBOpts,
                       Type,
                       Socket
                      ),
            NewStream = #active_stream{
                           id = StreamId,
                           pid = Pid,
                           notify_pid=NotifyPid,
                           send_window_size=InitialSendWindow,
                           recv_window_size=InitialRecvWindow
                          },
            case upsert(NewStream, StreamSet) of
                {error, ?REFUSED_STREAM} ->
                    %% This should be very rare, if it ever happens at
                    %% all. The case clause above tests the same
                    %% condition that upsert/2 checks to return this
                    %% result. Still, we need this case statement
                    %% because returning an {error tuple here would be
                    %% catastrophic

                    %% If this did happen, we need to kill this
                    %% process, or it will just hang out there.
                    h2_stream:stop(Pid),
                    {error, ?REFUSED_STREAM, #closed_stream{id=StreamId}};
                NewStreamSet ->
                    {Pid, NewStreamSet}
            end
    end.

-spec get_peer_subset(
        stream_id(),
        stream_set()) ->
                               peer_subset().
get_peer_subset(Id, StreamSet) ->
    case {Id rem 2, StreamSet#stream_set.type} of
        {0, client} ->
            StreamSet#stream_set.theirs;
        {1, client} ->
            StreamSet#stream_set.mine;
        {0, server} ->
            StreamSet#stream_set.mine;
        {1, server} ->
            StreamSet#stream_set.theirs
    end.

-spec set_peer_subset(
        Id :: stream_id(),
        StreamSet :: stream_set(),
        NewPeerSubset :: peer_subset()
                         ) ->
                             stream_set().
set_peer_subset(Id, StreamSet, NewPeerSubset) ->
    case {Id rem 2, StreamSet#stream_set.type} of
        {0, client} ->
            StreamSet#stream_set{
              theirs=NewPeerSubset
             };
        {1, client} ->
            StreamSet#stream_set{
              mine=NewPeerSubset
             };
        {0, server} ->
            StreamSet#stream_set{
              mine=NewPeerSubset
             };
        {1, server} ->
            StreamSet#stream_set{
              theirs=NewPeerSubset
             }
    end.

%% get/2 gets a stream. The logic in here basically just chooses which
%% subset.
-spec get(Id :: stream_id(),
          Streams :: stream_set()) ->
                 stream().
get(Id, StreamSet) ->
    get_from_subset(Id,
                    get_peer_subset(
                      Id,
                      StreamSet)).

-spec get_from_subset(
        Id :: stream_id(),
        PeerSubset :: peer_subset())
                     ->
                             stream().
get_from_subset(Id,
                #peer_subset{
                   lowest_stream_id=Lowest
                  })
  when Id < Lowest ->
    #closed_stream{id=Id};
get_from_subset(Id,
                #peer_subset{
                   next_available_stream_id=Next
                  })
  when Id >= Next ->
    #idle_stream{id=Id};
get_from_subset(Id, PeerSubset) ->
    case lists:keyfind(Id, 2, PeerSubset#peer_subset.active) of
        false ->
            #closed_stream{id=Id};
        Stream ->
            Stream
    end.

-spec upsert(
        Stream :: stream(),
        StreamSet :: stream_set()) ->
                    stream_set()
                  | {error, error_code()}.
%% Can't store idle streams
upsert(#idle_stream{}, StreamSet) ->
    StreamSet;
upsert(Stream, StreamSet) ->
    StreamId = stream_id(Stream),
    PeerSubset = get_peer_subset(StreamId, StreamSet),
    case upsert_peer_subset(Stream, PeerSubset) of
        {error, Code} ->
            {error, Code};
        NewPeerSubset ->
            set_peer_subset(StreamId, StreamSet, NewPeerSubset)
    end.

-spec upsert_peer_subset(
        Stream :: closed_stream() | active_stream(),
        PeerSubset :: peer_subset()
                      ) ->
                    peer_subset()
                  | {error, error_code()}.
%% Case 1: We're upserting a closed stream, it contains garbage we
%% don't care about and it's in the range of streams we're actively
%% tracking We remove it, and move the lowest_active pointer.
upsert_peer_subset(
  #closed_stream{
     id=Id,
     garbage=true
    },
  PeerSubset)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    OldStream = get_from_subset(Id, PeerSubset),
    OldType = type(OldStream),
    ActiveDiff =
        case OldType of
            closed -> 0;
            active -> -1
        end,

    NewActive = lists:keydelete(Id, 2, PeerSubset#peer_subset.active),
    %% NewActive could now have a #closed_stream with no information
    %% in it as the lowest active stream, so we should drop those.
    OptimizedNewActive = drop_unneeded_streams(NewActive),

    case OptimizedNewActive of
        [] ->
            PeerSubset#peer_subset{
              lowest_stream_id=PeerSubset#peer_subset.next_available_stream_id,
              active_count=0,
              active=[]
             };
        [NewLowestStream|_] ->
            NewLowest = stream_id(NewLowestStream),
            PeerSubset#peer_subset{
              lowest_stream_id=NewLowest,
              active_count=PeerSubset#peer_subset.active_count+ActiveDiff,
              active=OptimizedNewActive
             }
    end;
%% Case 2: Like case 1, but it's not garbage
upsert_peer_subset(
  #closed_stream{
     id=Id,
     garbage=false
    }=Closed,
  PeerSubset)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    OldStream = get_from_subset(Id, PeerSubset),
    OldType = type(OldStream),
    ActiveDiff =
        case OldType of
            closed -> 0;
            active -> -1
        end,

    NewActive = lists:keyreplace(Id, 2, PeerSubset#peer_subset.active, Closed),
    PeerSubset#peer_subset{
      active_count=PeerSubset#peer_subset.active_count+ActiveDiff,
      active=NewActive
     };
%% Case 3: It's closed, but greater than or equal to next available:
upsert_peer_subset(
  #closed_stream{
     id=Id
    } = Closed,
  PeerSubset)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->
    PeerSubset#peer_subset{
      next_available_stream_id=Id+2,
      active=lists:keystore(Id, 2, PeerSubset#peer_subset.active, Closed)
     };
%% Case 4: It's active, and in the range we're working with
upsert_peer_subset(
  #active_stream{
     id=Id
    }=Stream,
  PeerSubset)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    PeerSubset#peer_subset{
      active = lists:keystore(Id, 2, PeerSubset#peer_subset.active, Stream)
     };
%% Case 5: It's active, but it wasn't active before and activating it
%% would exceed our concurrent stream limits
upsert_peer_subset(
  #active_stream{},
  PeerSubset)
  when PeerSubset#peer_subset.max_active =/= unlimited,
       PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active ->
    {error, ?REFUSED_STREAM};
%% Case 6: It's active, and greater than the range we're tracking
upsert_peer_subset(
  #active_stream{
     id=Id
    }=Stream,
  PeerSubset)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->
    PeerSubset#peer_subset{
      next_available_stream_id=Id+2,
      active_count=PeerSubset#peer_subset.active_count+1,
      active = lists:keystore(Id, 2, PeerSubset#peer_subset.active, Stream)
     };
%% Catch All
%% TODO: remove this match and crash instead?
upsert_peer_subset(
  _Stream,
  PeerSubset) ->
    PeerSubset.


drop_unneeded_streams(Streams) ->
    SortedStreams = lists:keysort(2, Streams),
    lists:dropwhile(
      fun(#closed_stream{
             garbage=true
            }) ->
              true;
         (_) ->
              false
      end,
      SortedStreams).

-spec close(
        Stream :: stream(),
        Response :: garbage | {hpack:headers(), iodata()},
        Streams :: stream_set()
                   ) ->
                   { stream(), stream_set()}.
close(Stream,
      garbage,
      StreamSet) ->
    Closed = #closed_stream{
                id = stream_id(Stream),
                garbage=true
               },
    {Closed, upsert(Closed, StreamSet)};
close(Closed=#closed_stream{},
      _Response,
      Streams) ->
    {Closed, Streams};
close(_Idle=#idle_stream{id=StreamId},
      {Headers, Body, Trailers},
      Streams) ->
    Closed = #closed_stream{
                id=StreamId,
                response_headers=Headers,
                response_body=Body,
                response_trailers=Trailers
               },
    {Closed, upsert(Closed, Streams)};
close(#active_stream{
         id=Id,
         notify_pid=NotifyPid
        },
      {Headers, Body, Trailers},
      Streams) ->
    Closed = #closed_stream{
                id=Id,
                response_headers=Headers,
                response_body=Body,
                response_trailers=Trailers,
                notify_pid=NotifyPid
               },
    {Closed, upsert(Closed, Streams)}.

%% TODO: Change sort to send peer_initiated first!
-spec sort(StreamSet::stream_set()) -> stream_set().
sort(StreamSet) ->
    StreamSet#stream_set{
      theirs = sort_peer_subset(StreamSet#stream_set.theirs),
      mine = sort_peer_subset(StreamSet#stream_set.mine)
     }.

sort_peer_subset(PeerSubset) ->
    PeerSubset#peer_subset{
      active=lists:keysort(2, PeerSubset#peer_subset.active)
     }.

-spec update_all_recv_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_recv_windows(Delta, Streams) ->
    Streams#stream_set{
      theirs=update_all_recv_windows_subset(Delta, Streams#stream_set.theirs),
      mine=update_all_recv_windows_subset(Delta, Streams#stream_set.mine)
     }.

update_all_recv_windows_subset(Delta, PeerSubset) ->
    NewActive = lists:map(
                  fun(#active_stream{}=S) ->
                          S#active_stream{
                            recv_window_size=S#active_stream.recv_window_size+Delta
                           };
                     (S) -> S
                  end,
                  PeerSubset#peer_subset.active),
    PeerSubset#peer_subset{
      active=NewActive
     }.

-spec update_all_send_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_send_windows(Delta, Streams) ->
    Streams#stream_set{
      theirs=update_all_send_windows_subset(Delta, Streams#stream_set.theirs),
      mine=update_all_recv_windows_subset(Delta, Streams#stream_set.mine)
     }.

update_all_send_windows_subset(Delta, PeerSubset) ->
    NewActive = lists:map(
                  fun(#active_stream{}=S) ->
                          S#active_stream{
                            send_window_size=S#active_stream.send_window_size+Delta
                           };
                     (S) -> S
                  end,
                  PeerSubset#peer_subset.active),
    PeerSubset#peer_subset{
      active=NewActive
     }.

-spec update_their_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_their_max_active(NewMax,
                       #stream_set{
                          theirs=Theirs
                         }=Streams) ->
    Streams#stream_set{
      theirs=Theirs#peer_subset{max_active=NewMax}
     }.

-spec update_my_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_my_max_active(NewMax,
                       #stream_set{
                          mine=Mine
                         }=Streams) ->
    Streams#stream_set{
      mine=Mine#peer_subset{max_active=NewMax}
     }.

-spec send_what_we_can(StreamId :: all | stream_id(),
                       ConnSendWindowSize :: integer(),
                       MaxFrameSize :: non_neg_integer(),
                       Streams :: stream_set()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: stream_set()}.
send_what_we_can(all, ConnSendWindowSize, MaxFrameSize, Streams) ->
    {AfterPeerWindowSize,
     NewPeerInitiated} = c_send_what_we_can(
                           ConnSendWindowSize,
                           MaxFrameSize,
                           Streams#stream_set.theirs#peer_subset.active,
                           []),
    {AfterAfterWindowSize,
     NewSelfInitiated} = c_send_what_we_can(
                           AfterPeerWindowSize,
                           MaxFrameSize,
                           Streams#stream_set.mine#peer_subset.active,
                           []),

    {AfterAfterWindowSize,
     Streams#stream_set{
       theirs=Streams#stream_set.theirs#peer_subset{active=NewPeerInitiated},
       mine=Streams#stream_set.mine#peer_subset{active=NewSelfInitiated}
      }
    };
send_what_we_can(StreamId, ConnSendWindowSize, MaxFrameSize, Streams) ->
    {NewConnSendWindowSize, NewStream} =
        s_send_what_we_can(ConnSendWindowSize,
                           MaxFrameSize,
                           get(StreamId, Streams)),
    {NewConnSendWindowSize,
     upsert(NewStream, Streams)}.

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
s_send_what_we_can(SWS, _, #active_stream{queued_data=Data,
                                          trailers=undefined}=S)
  when is_atom(Data) ->
    {SWS, S};
s_send_what_we_can(SWS, _, #active_stream{queued_data=Data,
                                          id=_StreamId,
                                          pid=Pid,
                                          trailers=Trailers}=S)
  when is_atom(Data) ->
    h2_stream:send_trailers(Pid, Trailers),
    {SWS, S#active_stream{trailers=undefined}};
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
                  h2_frame_data:new(Stream#active_stream.queued_data)},  %% Full Body
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
                  h2_frame_data:new(BinToSend)},
                 MaxToSend,
                 Stream#active_stream{
                   queued_data=Rest,
                   send_window_size=SSWS-MaxToSend}}
        end,

    _Sent = h2_stream:send_data(Stream#active_stream.pid, Frame),

    NewS1 = case NewS of
                #active_stream{trailers=undefined} ->
                    NewS;
                #active_stream{pid=Pid,
                               queued_data=done,
                               trailers=Trailers1} ->
                    h2_stream:send_trailers(Pid, Trailers1),
                    NewS#active_stream{trailers=undefined};
                _ ->
                    NewS
            end,

    case ExitStrategy of
        max_frame_size ->
            s_send_what_we_can(SWS - SentBytes, MFS, NewS1);
        stream ->
            {SWS - SentBytes, NewS1};
        connection ->
            {SWS - SentBytes, NewS1}
    end;
s_send_what_we_can(SWS, _MFS, NonActiveStream) ->
    {SWS, NonActiveStream}.


%% Record Accessors
-spec stream_id(
        Stream :: stream()) ->
                       stream_id().
stream_id(#idle_stream{id=SID}) ->
    SID;
stream_id(#active_stream{id=SID}) ->
    SID;
stream_id(#closed_stream{id=SID}) ->
    SID.

-spec pid(stream()) -> pid() | undefined.
pid(#active_stream{pid=Pid}) ->
    Pid;
pid(_) ->
    undefined.

-spec type(stream()) -> idle | active | closed.
type(#idle_stream{}) ->
    idle;
type(#active_stream{}) ->
    active;
type(#closed_stream{}) ->
    closed.

queued_data(#active_stream{queued_data=QD}) ->
    QD;
queued_data(_) ->
    undefined.

update_trailers(Trailers, Stream=#active_stream{}) ->
    Stream#active_stream{trailers=Trailers}.

update_data_queue(
  NewBody,
  BodyComplete,
  #active_stream{} = Stream) ->
    Stream#active_stream{
      queued_data=NewBody,
      body_complete=BodyComplete
     };
update_data_queue(_, _, S) ->
    S.

response(#closed_stream{
            response_headers=Headers,
            response_trailers=Trailers,
            response_body=Body}) ->
    Encoding = case lists:keyfind(<<"content-encoding">>, 1, Headers) of
        false -> identity;
        {_, Encoding0} -> binary_to_atom(Encoding0, 'utf8')
    end,
    {Headers, decode_body(Body, Encoding), Trailers};
response(_) ->
    no_response.

decode_body(Body, identity) ->
    Body;
decode_body(Body, gzip) ->
    zlib:gunzip(Body);
decode_body(Body, zip) ->
    zlib:unzip(Body);
decode_body(Body, compress) ->
    zlib:uncompress(Body);
decode_body(Body, deflate) ->
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, -15),
    Decompressed = try zlib:inflate(Z, Body) catch E:V -> {E,V} end,
    ok = zlib:inflateEnd(Z),
    ok = zlib:close(Z),
    iolist_to_binary(Decompressed).

recv_window_size(#active_stream{recv_window_size=RWS}) ->
    RWS;
recv_window_size(_) ->
    undefined.

decrement_recv_window(
  L,
  #active_stream{recv_window_size=RWS}=Stream
 ) ->
    Stream#active_stream{
      recv_window_size=RWS-L
     };
decrement_recv_window(_, S) ->
    S.

send_window_size(#active_stream{send_window_size=SWS}) ->
    SWS;
send_window_size(_) ->
    undefined.

increment_send_window_size(
  WSI,
  #active_stream{send_window_size=SWS}=Stream) ->
    Stream#active_stream{
      send_window_size=SWS+WSI
     };
increment_send_window_size(_WSI, Stream) ->
    Stream.

stream_pid(#active_stream{pid=Pid}) ->
    Pid;
stream_pid(_) ->
    undefined.

%% the false clause is here as an artifact of us using a simple
%% lists:keyfind
notify_pid(#idle_stream{}) ->
    undefined;
notify_pid(#active_stream{notify_pid=Pid}) ->
    Pid;
notify_pid(#closed_stream{notify_pid=Pid}) ->
    Pid.

%% The number of #active_stream records
-spec my_active_count(stream_set()) -> non_neg_integer().
my_active_count(SS) ->
    SS#stream_set.mine#peer_subset.active_count.

%% The number of #active_stream records
-spec their_active_count(stream_set()) -> non_neg_integer().
their_active_count(SS) ->
    SS#stream_set.theirs#peer_subset.active_count.

%% The list of #active_streams, and un gc'd #closed_streams
-spec my_active_streams(stream_set()) -> [stream()].
my_active_streams(SS) ->
    SS#stream_set.mine#peer_subset.active.

%% The list of #active_streams, and un gc'd #closed_streams
-spec their_active_streams(stream_set()) -> [stream()].
their_active_streams(SS) ->
    SS#stream_set.theirs#peer_subset.active.

%% My MCS (max_active)
-spec my_max_active(stream_set()) -> non_neg_integer().
my_max_active(SS) ->
    SS#stream_set.mine#peer_subset.max_active.

%% Their MCS (max_active)
-spec their_max_active(stream_set()) -> non_neg_integer().
their_max_active(SS) ->
    SS#stream_set.theirs#peer_subset.max_active.
