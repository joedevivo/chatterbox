-module(h2_stream_set).
-include("http2.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
%-compile([export_all]).

%% This module exists to manage a set of all streams for a given
%% connection. When a connection starts, a stream set logically
%% contains streams from id 1 to 2^31-1. In practicality, storing that
%% many idle streams in a collection of any type would be more memory
%% intensive. We're going to manage that here in this module, but to
%% the outside, it will behave as if they all exist

-define(RECV_WINDOW_SIZE, 1).
-define(SEND_WINDOW_SIZE, 2).
-define(MY_NEXT_AVAILABLE_STREAM_ID, 3).
-define(THEIR_NEXT_AVAILABLE_STREAM_ID, 4).
-define(MY_ACTIVE_COUNT, 5).
-define(THEIR_ACTIVE_COUNT, 6).
-define(LAST_SEND_ALL_WE_CAN_STREAM_ID, 7).

-record(
   stream_set,
   {
     %% Type determines which streams are mine, and which are theirs
     type :: client | server,

     atomics = atomics:new(7, []),

     socket :: sock:socket(),

     connection :: pid(),

     table = ets:new(?MODULE, [public, {keypos, 2}, {read_concurrency, true}]) :: ets:tab(),
     %% Streams initiated by this peer
     %% mine :: peer_subset(),
     %% Streams initiated by the other peer
     %% theirs :: peer_subset()
     callback_mod = undefined :: atom(),
     callback_opts = [] :: list(),
     garbage_on_end = false :: boolean()
   }).
-type stream_set() :: #stream_set{}.
-export_type([stream_set/0]).

-record(connection_settings, {
          type :: self_settings | peer_settings,
          settings = #settings{} :: settings() | locked
         }).

-record(context, {
          type = encode_context :: encode_context,
          context = hpack:new_context() :: hpack:context() | locked
         }).

%% The stream_set needs to keep track of two subsets of streams, one
%% for the streams that it has initiated, and one for the streams that
%% have been initiated on the other side of the connection. It is this
%% peer_subset that will try to optimize the set of stream metadata
%% that we're storing in memory. For each side of the connection, we
%% also need an accurate count of how many are currently active

-record(
   peer_subset,
   {
     type :: mine | theirs,
     %% Provided by the connection settings, we can check against this
     %% every time we try to add a stream to this subset
     max_active = unlimited :: unlimited | pos_integer(),
     %% A counter that's an accurate reflection of the number of
     %% active streams
     active_count = 0 :: non_neg_integer(),

     %% Next available stream id will be the stream id of the next
     %% stream that can be added to this subset. That means if asked
     %% for a stream with this id or higher, the stream type returned
     %% must be idle. Any stream id lower than this that isn't active
     %% must be of type closed.
     next_available_stream_id :: stream_id()
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
    new/5,
    new_stream/5,
    get/2,
    update/3,
    get_callback/1,
    socket/1,
    connection/1
   ]).

%% Accessors
-export(
   [
    queued_data/1,
    update_trailers/2,
    update_data_queue/3,
    decrement_recv_window/2,
    recv_window_size/1,
    decrement_socket_recv_window/2,
    increment_socket_recv_window/2,
    socket_recv_window_size/1,
    set_socket_recv_window_size/2,
    decrement_socket_send_window/2,
    increment_socket_send_window/2,
    socket_send_window_size/1,
    set_socket_send_window_size/2,

    response/1,
    send_window_size/1,
    increment_send_window_size/2,
    pid/1,
    stream_id/1,
    stream_pid/1,
    notify_pid/1,
    type/1,
    stream_set_type/1,
    my_active_count/1,
    their_active_count/1,
    my_active_streams/1,
    their_active_streams/1,
    my_max_active/1,
    their_max_active/1,
    get_next_available_stream_id/1,
    get_settings/1,
    get_self_settings/1,
    get_peer_settings/1,
    get_self_settings_locked/1,
    get_peer_settings_locked/1,
    update_self_settings/2,
    update_peer_settings/2,
    get_encode_context/1,
    get_encode_context/2,
    release_encode_context/2,
    get_garbage_on_end/1
   ]
  ).

-export(
   [
    close/3,
    send_all_we_can/1,
    send_what_we_can/3,
    update_all_recv_windows/2,
    update_all_send_windows/2,
    update_their_max_active/2,
    update_my_max_active/2
   ]
  ).

%% new/1 returns a new stream_set. This is your constructor.
-spec new(
        client | server,
        sock:socket(),
        atom(), list(), boolean()
       ) -> stream_set().
new(client, Socket, CallbackMod, CallbackOpts, GarbageOnEnd) ->
    StreamSet = #stream_set{
        callback_mod = CallbackMod,
        callback_opts = CallbackOpts,
        socket=Socket,
        connection=self(),
        garbage_on_end=GarbageOnEnd,
       type=client},
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=self_settings}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=peer_settings}),
    ets:insert_new(StreamSet#stream_set.table, #context{}),
    atomics:put(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 1),
    atomics:put(StreamSet#stream_set.atomics, ?THEIR_NEXT_AVAILABLE_STREAM_ID, 2),
    atomics:put(StreamSet#stream_set.atomics, ?MY_ACTIVE_COUNT, 0),
    atomics:put(StreamSet#stream_set.atomics, ?THEIR_ACTIVE_COUNT, 0),
    atomics:put(StreamSet#stream_set.atomics, ?LAST_SEND_ALL_WE_CAN_STREAM_ID, 0),
    %% I'm a client, so mine are always odd numbered
    ets:insert_new(StreamSet#stream_set.table,
                   #peer_subset{
                      type=mine,
                      next_available_stream_id=1
                     }),
    %% And theirs are always even
     ets:insert_new(StreamSet#stream_set.table, 
                    #peer_subset{
                       type=theirs,
                       next_available_stream_id=2
                      }),
    StreamSet;
new(server, Socket, CallbackMod, CallbackOpts, GarbageOnEnd) ->
    StreamSet = #stream_set{
       callback_mod = CallbackMod,
       callback_opts = CallbackOpts,
       socket=Socket,
       connection=self(),
       garbage_on_end=GarbageOnEnd,
       type=server},
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=self_settings}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=peer_settings}),
    ets:insert_new(StreamSet#stream_set.table, #context{}),
    %% I'm a server, so mine are always even numbered
    atomics:put(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2),
    atomics:put(StreamSet#stream_set.atomics, ?THEIR_NEXT_AVAILABLE_STREAM_ID, 1),
    atomics:put(StreamSet#stream_set.atomics, ?MY_ACTIVE_COUNT, 0),
    atomics:put(StreamSet#stream_set.atomics, ?THEIR_ACTIVE_COUNT, 0),
    atomics:put(StreamSet#stream_set.atomics, ?LAST_SEND_ALL_WE_CAN_STREAM_ID, 0),
    ets:insert_new(StreamSet#stream_set.table,
                   #peer_subset{
                      type=mine,
                      next_available_stream_id=2
                     }),
    %% And theirs are always odd
     ets:insert_new(StreamSet#stream_set.table, 
                    #peer_subset{
                       type=theirs,
                       next_available_stream_id=1
                      }),
    StreamSet.

-spec new_stream(
    StreamId :: stream_id() | next,
    NotifyPid :: pid(),
    CBMod :: module(),
    CBOpts :: list(),
    StreamSet :: stream_set()
) -> {pid(), stream_id(), stream_set()} | {error, error_code(), closed_stream()}.
new_stream(
    StreamId0,
    NotifyPid,
    CBMod,
    CBOpts,
    StreamSet
) ->
    {SelfSettings, PeerSettings} = get_settings(StreamSet),
    InitialSendWindow = PeerSettings#settings.initial_window_size,
    InitialRecvWindow = SelfSettings#settings.initial_window_size,
    {PeerSubset, StreamId} = case StreamId0 of 
                                 next ->
                                     Next = atomics:add_get(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2),
                                     P0 = get_my_peers(StreamSet),
                                     {P0, Next - 2};
                                 Id ->
                                     {get_peer_subset(Id, StreamSet), Id}
                             end,

    case PeerSubset#peer_subset.max_active =/= unlimited andalso
         PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active
    of
        true ->
            {error, ?REFUSED_STREAM, #closed_stream{id=StreamId}};
        false ->
            {ok, Pid} = case self() == StreamSet#stream_set.connection of
                            true ->
                                h2_stream:start_link(
                                  StreamId,
                                  StreamSet,
                                  self(),
                                  CBMod,
                                  CBOpts
                                 );
                            false ->
                                h2_stream:start(
                                  StreamId,
                                  StreamSet,
                                  StreamSet#stream_set.connection,
                                  CBMod,
                                  CBOpts
                                 )
                        end,
                    NewStream = #active_stream{
                           id = StreamId,
                           pid = Pid,
                           notify_pid=NotifyPid,
                           send_window_size=InitialSendWindow,
                           recv_window_size=InitialRecvWindow
                          },
                    true = ets:insert_new(StreamSet#stream_set.table, NewStream),
            case upsert_peer_subset(#idle_stream{id=StreamId}, NewStream, get_peer_subset(StreamId, StreamSet), StreamSet) of
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
                ok ->
                    {Pid, StreamId, StreamSet}
            end
    end.

get_callback(#stream_set{callback_mod=CM, callback_opts = CO}) ->
    {CM, CO}.

socket(#stream_set{socket=Sock}) ->
    Sock.

connection(#stream_set{connection=Conn}) ->
    Conn.

get_self_settings(StreamSet) ->
    try hd(ets:lookup(StreamSet#stream_set.table, self_settings)) of
        #connection_settings{settings=locked} ->
            timer:sleep(1),
            get_self_settings(StreamSet);
        #connection_settings{settings=Settings} ->
            Settings
    catch
        error:badarg ->
            #settings{}
    end.

get_peer_settings(StreamSet) ->
    try hd(ets:lookup(StreamSet#stream_set.table, peer_settings)) of
        #connection_settings{settings=locked} ->
            timer:sleep(1),
            get_self_settings(StreamSet);
        #connection_settings{settings=Settings} ->
            Settings
    catch error:badarg ->
              #settings{}
    end.

get_self_settings_locked(StreamSet=#stream_set{table=T}) ->
    SelfSettings = get_self_settings(StreamSet),
    try ets:select_replace(T, [{#connection_settings{type=self_settings, settings=SelfSettings}, [], [{const, #connection_settings{type=self_settings, settings=locked}}]}]) of
        1 ->
            SelfSettings;
        0 ->
            timer:sleep(1),
            get_self_settings_locked(StreamSet)
    catch
        error:badarg ->
            #settings{}
    end.

get_peer_settings_locked(StreamSet=#stream_set{table=T}) ->
    PeerSettings = get_peer_settings(StreamSet),
    try ets:select_replace(T, [{#connection_settings{type=peer_settings, settings=PeerSettings}, [], [{const, #connection_settings{type=peer_settings, settings=locked}}]}]) of
        1 ->
            PeerSettings;
        0 ->
            timer:sleep(1),
            get_peer_settings_locked(StreamSet)
    catch
        error:badarg ->
            #settings{}
    end.

get_settings(StreamSet) ->
    {get_self_settings(StreamSet), get_peer_settings(StreamSet)}.

update_self_settings(#stream_set{table=T}, Settings) ->
    try ets:select_replace(T, [{#connection_settings{type=self_settings, settings=locked}, [], [{const, #connection_settings{type=self_settings, settings=Settings}}]}]) of
        1 -> ok
    catch 
        error:badarg ->
              ok
    end.

update_peer_settings(#stream_set{table=T}, Settings) ->
    try ets:select_replace(T, [{#connection_settings{type=peer_settings, settings=locked}, [], [{const, #connection_settings{type=peer_settings, settings=Settings}}]}]) of
        1 -> ok
    catch
        error:badarg ->
            ok
    end.

get_encode_context(StreamSet) ->
    get_encode_context(StreamSet, force).

get_encode_context(StreamSet, Headers) ->
    try (hd(ets:lookup(StreamSet#stream_set.table, encode_context))) of
        #context{context=locked} ->
            timer:sleep(1),
            get_encode_context(StreamSet, Headers);
        Encoder=#context{context=EncodeContext} ->
            case Headers /= force andalso hpack:all_fields_indexed(Headers, EncodeContext) of
                true ->
                    %% we don't have any new headers, so we don't need the lock
                    {nolock, EncodeContext};
                false ->
                    case ets:select_replace(StreamSet#stream_set.table, [{Encoder, [], [{const, #context{type=encode_context, context=locked}}]}]) of
                        1 ->
                            %% ok we have the ownership of this now
                            {lock, EncodeContext};
                        0 ->
                            timer:sleep(1),
                            get_encode_context(StreamSet, Headers)
                    end
            end
    catch
        error:badarg ->
            {nolock, hpack:new_context()}
    end.

release_encode_context(_StreamSet, {nolock, _}) ->
    ok;
release_encode_context(StreamSet, {lock, NewEncoder}) ->
    try ets:select_replace(StreamSet#stream_set.table, [{#context{type=encode_context, context=locked}, [], [{const, #context{type=encode_context, context=NewEncoder}}]}]) of
        1 -> ok
    catch
        error:badarg ->
            ok
    end.

-spec get_garbage_on_end(StreamSet :: stream_set()) -> boolean().
get_garbage_on_end(StreamSet) ->
    StreamSet#stream_set.garbage_on_end.

-spec get_peer_subset(
        stream_id(),
        stream_set()) ->
                               peer_subset().
get_peer_subset(Id, StreamSet) ->
    case {Id rem 2, StreamSet#stream_set.type} of
        {0, client} ->
            get_their_peers(StreamSet);
        {1, client} ->
            get_my_peers(StreamSet);
        {0, server} ->
            get_my_peers(StreamSet);
        {1, server} ->
            get_their_peers(StreamSet)
    end.

-spec get_my_peers(stream_set()) -> peer_subset().
get_my_peers(StreamSet) ->
    Next = atomics:get(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID),
    Active = atomics:get(StreamSet#stream_set.atomics, ?MY_ACTIVE_COUNT),
    try (hd(ets:lookup(StreamSet#stream_set.table, mine)))#peer_subset{next_available_stream_id=Next, active_count=Active}
    catch error:badarg -> #peer_subset{type=mine, next_available_stream_id=0}
    end.

-spec get_their_peers(stream_set()) -> peer_subset().
get_their_peers(StreamSet) ->
    Next = atomics:get(StreamSet#stream_set.atomics, ?THEIR_NEXT_AVAILABLE_STREAM_ID),
    Active = atomics:get(StreamSet#stream_set.atomics, ?THEIR_ACTIVE_COUNT),
    try (hd(ets:lookup(StreamSet#stream_set.table, theirs)))#peer_subset{active_count=Active, next_available_stream_id=Next}
    catch error:badarg -> #peer_subset{type=theirs, next_available_stream_id=0}
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
                      StreamSet), StreamSet).


-spec get_from_subset(
        Id :: stream_id(),
        PeerSubset :: peer_subset(),
        StreamSet :: stream_set())
                     ->
    stream().
get_from_subset(Id,
                #peer_subset{
                   next_available_stream_id=Next
                  }, _StreamSet)
  when Id >= Next ->
    #idle_stream{id=Id};
get_from_subset(Id, _PeerSubset, StreamSet) ->
    try ets:lookup(StreamSet#stream_set.table, Id)  of
        [] ->
            #closed_stream{id=Id};
        [Stream] ->
            Stream
    catch
        error:badarg ->
            #closed_stream{id=Id}
    end.


update(StreamId, Fun, StreamSet) ->
    case get(StreamId, StreamSet) of
        #idle_stream{} ->
            case Fun(#idle_stream{id=StreamId}) of
                {#idle_stream{}, _} ->
                    %% Can't store idle streams
                    ok;
                {NewStream, Data} ->
                    case ets:insert_new(StreamSet#stream_set.table, NewStream) of
                        true ->
                            PeerSubset = get_peer_subset(StreamId, StreamSet),
                            case upsert_peer_subset(#idle_stream{id=StreamId}, NewStream, PeerSubset, StreamSet) of
                                {error, Code} ->
                                    {error, Code};
                                ok ->
                                    {ok, Data}
                            end;
                        false ->
                            timer:sleep(1),
                            %% somebody beat us to it, try again
                            update(StreamId, Fun, StreamSet)
                    end;
                ignore ->
                    ok
            end;
        Stream ->
            case Fun(Stream) of
                ignore ->
                    ok;
                {Stream, Data} ->
                    %% stream did not change
                    {ok, Data};
                {NewStream, Data} ->
                    try ets:select_replace(StreamSet#stream_set.table, [{Stream, [], [{const, NewStream}]}]) of
                        1 ->
                            PeerSubset = get_peer_subset(StreamId, StreamSet),
                            case upsert_peer_subset(Stream, NewStream, PeerSubset, StreamSet) of
                                {error, Code} ->
                                    {error, Code};
                                ok ->
                                    {ok, Data}
                            end;
                        0 ->
                            timer:sleep(1),
                            update(StreamId, Fun, StreamSet)
                    catch
                        error:badarg -> ok
                    end
            end
    end.

-spec upsert_peer_subset(
        OldStream :: idle_stream() | closed_stream() | active_stream(),
        Stream :: closed_stream() | active_stream(),
        PeerSubset :: peer_subset(),
        StreamSet :: stream_set()
                      ) ->
                    ok
                  | {error, error_code()}.
%% Case 2: Like case 1, but it's not garbage
upsert_peer_subset(
  OldStream,
  #closed_stream{
     id=Id,
     garbage=Garbage
    },
  PeerSubset, StreamSet)
  when Id < PeerSubset#peer_subset.next_available_stream_id ->
    OldType = type(OldStream),
    case OldType of
        active ->
            Counter = case PeerSubset#peer_subset.type of
                mine ->
                    ?MY_ACTIVE_COUNT;
                theirs ->
                    ?THEIR_ACTIVE_COUNT
            end,
            atomics:sub(StreamSet#stream_set.atomics, Counter, 1),
            ok;
        _ -> ok
    end,
    case Garbage of
        true ->
            %% just delete it
            ets:delete(StreamSet#stream_set.table, Id),
            ok;
        false ->
            ok
    end;
%% Case 3: It's closed, but greater than or equal to next available:
upsert_peer_subset(
  OldStream,
  #closed_stream{
     id=Id
    },
  PeerSubset, StreamSet)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->
    case PeerSubset#peer_subset.type of
        mine ->
            case OldStream of
                #active_stream{} ->
                    atomics:sub(StreamSet#stream_set.atomics, ?MY_ACTIVE_COUNT, 1),
                    ok;
                _ ->
                    ok
            end,
            atomics:add(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2);
        theirs ->
            case OldStream of
                #active_stream{} ->
                    atomics:sub(StreamSet#stream_set.atomics, ?THEIR_ACTIVE_COUNT, 1),
                    ok;
                _ ->
                    ok
            end,
            atomics:compare_exchange(StreamSet#stream_set.atomics, ?THEIR_NEXT_AVAILABLE_STREAM_ID, PeerSubset#peer_subset.next_available_stream_id, Id+2)
    end,
    ok;
%% Case 4: It's active, and in the range we're working with
upsert_peer_subset(
  OldStream,
  #active_stream{
     id=Id
    },
  PeerSubset, StreamSet)
  when Id < PeerSubset#peer_subset.next_available_stream_id ->
    case OldStream of
        #idle_stream{} ->
            Counter = case PeerSubset#peer_subset.type of
                mine ->
                    ?MY_ACTIVE_COUNT;
                theirs ->
                    ?THEIR_ACTIVE_COUNT
            end,
            atomics:add(StreamSet#stream_set.atomics, Counter, 1),
            ok;
        _ ->
            ok
    end;
%% Case 5: It's active, but it wasn't active before and activating it
%% would exceed our concurrent stream limits
upsert_peer_subset(
  _OldStream,
  #active_stream{},
  PeerSubset, _StreamSet)
  when PeerSubset#peer_subset.max_active =/= unlimited,
       PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active ->
    {error, ?REFUSED_STREAM};
%% Case 6: It's active, and greater than the range we're tracking
upsert_peer_subset(
  _OldStream,
  #active_stream{
     id=Id
    },
  PeerSubset, StreamSet)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->
    case PeerSubset#peer_subset.type of
        mine ->
            atomics:add(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2),
            atomics:add(StreamSet#stream_set.atomics, ?MY_ACTIVE_COUNT, 1),
            ok;
        theirs ->
            atomics:compare_exchange(StreamSet#stream_set.atomics, ?THEIR_NEXT_AVAILABLE_STREAM_ID, PeerSubset#peer_subset.next_available_stream_id, Id+2),
            atomics:add(StreamSet#stream_set.atomics, ?THEIR_ACTIVE_COUNT, 1),
            ok
    end.

-spec close(
        Stream :: stream(),
        Response :: garbage | {hpack:headers(), iodata(), hpack:headers() | undefined},
        Streams :: stream_set()
                   ) ->
                   { stream(), stream_set()}.
close(Stream0,
      garbage,
      StreamSet) ->

    {ok, Closed} = update(stream_id(Stream0),
           fun(Stream) ->
                   NewStream = #closed_stream{
                      id = stream_id(Stream),
                      garbage=true
                     },
                   {NewStream, NewStream}
           end, StreamSet),
    {Closed, StreamSet};
close(Closed=#closed_stream{},
      _Response,
      Streams) ->
    {Closed, Streams};
close(_Idle=#idle_stream{id=StreamId},
      {Headers, Body, Trailers},
      Streams) ->
    case update(StreamId,
                fun(#idle_stream{}) ->
                        NewStream = #closed_stream{
                                       id=StreamId,
                                       response_headers=Headers,
                                       response_body=Body,
                                       response_trailers=Trailers
                                      },
                        {NewStream, NewStream};
                   (#closed_stream{}=C) ->
                        {C, C};
                   (_) -> ignore
                end, Streams) of
        {ok, Closed} ->
            {Closed, Streams};
        ok ->
            close(get(StreamId, Streams), {Headers, Body, Trailers}, Streams)
    end;

close(#active_stream{
         id=Id
        },
      {Headers, Body, Trailers},
      Streams) ->
    case update(Id,
                fun(#active_stream{notify_pid=Pid}) ->
                        NewStream = #closed_stream{
                                       notify_pid=Pid,
                                       id=Id,
                                       response_headers=Headers,
                                       response_body=Body,
                                       response_trailers=Trailers
                                      },
                        {NewStream, NewStream};
                   (#closed_stream{}=C) ->
                        {C, C};
                   (_) -> ignore
                end, Streams) of
        {ok, Closed} ->
            {Closed, Streams};
        ok ->
            close(get(Id, Streams), {Headers, Body, Trailers}, Streams)
    end.

-spec update_all_recv_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_recv_windows(0, Streams) ->
    Streams;
update_all_recv_windows(Delta, Streams) ->

    catch ets:select_replace(Streams#stream_set.table,
      ets:fun2ms(fun(S=#active_stream{recv_window_size=Size}) ->
                         S#active_stream{recv_window_size=Size+Delta}
                 end)),
    Streams.

-spec update_all_send_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_send_windows(0, Streams) ->
    Streams;
update_all_send_windows(Delta, Streams) ->
    catch ets:select_replace(Streams#stream_set.table,
      ets:fun2ms(fun(S=#active_stream{send_window_size=Size}) ->
                         S#active_stream{send_window_size=Size+Delta}
                 end)),
    Streams.

-spec update_their_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_their_max_active(NewMax, Streams) ->
    try ets:select_replace(Streams#stream_set.table, ets:fun2ms(fun(#peer_subset{type=theirs}=PS) -> PS#peer_subset{max_active=NewMax} end)) of
        1 ->
            Streams;
        0 ->
            update_their_max_active(NewMax, Streams)
    catch
        error:badarg ->
            Streams
    end.

get_next_available_stream_id(Streams) ->
    (get_my_peers(Streams))#peer_subset.next_available_stream_id.

-spec update_my_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_my_max_active(NewMax, Streams) ->
    try ets:select_replace(Streams#stream_set.table, ets:fun2ms(fun(#peer_subset{type=mine}=PS) -> PS#peer_subset{max_active=NewMax} end)) of
        1 ->
            Streams;
        0 ->
            update_their_max_active(NewMax, Streams)
    catch
        error:badarg ->
            Streams
    end.

-spec send_all_we_can(Streams :: stream_set()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: stream_set()}.
send_all_we_can(Streams) ->
    PeerSettings = get_peer_settings(Streams),
    MaxFrameSize = PeerSettings#settings.max_frame_size,
    
    %% TODO be smarter about where we start off (remember where we last stopped, etc),
    %% inspect priorities, etc
    Last = atomics:get(Streams#stream_set.atomics, ?LAST_SEND_ALL_WE_CAN_STREAM_ID),
    case ets:select(Streams#stream_set.table, ets:fun2ms(fun(AS=#active_stream{id=Id, queued_data=D, trailers=T}) when Id > Last andalso ((not is_atom(D)) orelse T /= undefined)  -> AS end), 20) of
        '$end_of_table' ->
            ok;
        Res ->
            c_send_what_we_can(MaxFrameSize, Res, Streams)
    end,


    Last2 = atomics:get(Streams#stream_set.atomics, ?LAST_SEND_ALL_WE_CAN_STREAM_ID),

    case Last == Last2 of
        true ->
            %% we didn't run out of send window, so now traverse the
            %% streams we have not inspected yet
            case ets:select(Streams#stream_set.table, ets:fun2ms(fun(AS=#active_stream{id=Id, queued_data=D, trailers=T}) when Id =< Last andalso ((not is_atom(D)) orelse T /= undefined)  -> AS end), 20) of
                '$end_of_table' ->
                    ok;
                Res2 ->
                    c_send_what_we_can(MaxFrameSize, Res2, Streams)
            end;
        false ->
            %% we exhausted the send window, so do nothing here
            ok
    end,


    {socket_send_window_size(Streams),
     Streams}.

-spec send_what_we_can(StreamId :: stream_id(),
                       StreamFun :: fun((#active_stream{}) -> #active_stream{}),
                       Streams :: stream_set()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: stream_set()}.

send_what_we_can(StreamId, StreamFun, Streams) ->
    PeerSettings = get_peer_settings(Streams),
    MaxFrameSize = PeerSettings#settings.max_frame_size,


    NewConnSendWindowSize = s_send_what_we_can(MaxFrameSize,
                       StreamId,
                       StreamFun,
                       Streams),
    {NewConnSendWindowSize, Streams}.

%% Send at the connection level
-spec c_send_what_we_can(MaxFrameSize :: non_neg_integer(),
                         Streams :: {[stream()], term()},
                         StreamSet :: stream_set()
                        ) ->
                                integer().
c_send_what_we_can(MFS, {[], CC}, StreamSet) ->
    case ets:select(CC) of
        '$end_of_table' ->
            socket_send_window_size(StreamSet);
        Res ->
            c_send_what_we_can(MFS, Res, StreamSet)
    end;
c_send_what_we_can(MFS, {[S|Streams], CC}, StreamSet) ->
    NewSWS = s_send_what_we_can(MFS, stream_id(S), fun(Stream) -> Stream end, StreamSet),
    case NewSWS =< 0 of
        true ->
            %% If we hit =< 0, done
            %% track where we stopped
            atomics:put(StreamSet#stream_set.atomics, ?LAST_SEND_ALL_WE_CAN_STREAM_ID, stream_id(S)),
            NewSWS;
        false ->
            %% Otherwise, try sending on the next stream
            c_send_what_we_can(MFS, {Streams, CC}, StreamSet)
    end.

%% Send at the stream level
-spec s_send_what_we_can(MFS :: non_neg_integer(),
                         StreamId :: stream_id(),
                         StreamFun :: fun((stream()) -> stream()),
                         StreamSet :: stream_set()) ->
                                integer().
s_send_what_we_can(MFS, StreamId, StreamFun0, Streams) ->
    StreamFun = 
    fun(#active_stream{queued_data=Data, trailers=undefined}=Stream) when is_atom(Data) ->
            {Stream, {0, Stream, []}};
       (#active_stream{queued_data=Data, pid=Pid, trailers=Trailers}=S) when is_atom(Data) ->
            NewS = S#active_stream{trailers=undefined},
            {NewS, {0, S, [{send_trailers, Pid, Trailers}]}};
       (#active_stream{}=Stream) ->

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

            %% If it was connection send window size, we're blocked at the
            %% connection level and we should break out of this recursion

            %% If it was stream send_window size, we're blocked on this
            %% stream, but other streams can still go, so we'll break out of
            %% this recursion, but not the connection level

            SWS = socket_send_window_size(Streams),
            SSWS = Stream#active_stream.send_window_size,
            QueueSize = byte_size(Stream#active_stream.queued_data),

            {MaxToSend, _ExitStrategy} =
            case SWS < SSWS of
                %% take the smallest of SWS or SSWS, read that
                %% from the queue and break it up into MFS frames
                true ->
                    {SWS, connection};
                _ ->
                    {SSWS, stream}
            end,


            case MaxToSend > 0 of
                false ->
                    %% return the stream and not ignore because the apply fun
                    %% may have updated the stream
                    {Stream, {0, Stream, []}};
                true ->
                    {Frames, SentBytes, NewS} =
                    case MaxToSend >= QueueSize of
                        _ when MaxToSend == 0 ->
                            {[], 0, Stream};
                        true ->
                            EndStream = case Stream#active_stream.body_complete of
                                            true ->
                                                case Stream of
                                                    #active_stream{trailers=undefined} ->
                                                        true;
                                                    _ ->
                                                        false
                                                end;
                                            false -> false
                                        end,
                            %% We have the power to send everything
                            {chunk_to_frames(Stream#active_stream.queued_data, MFS, Stream#active_stream.id, EndStream, []),
                             QueueSize,
                             Stream#active_stream{
                               queued_data=done,
                               body_complete=true,
                               send_window_size=SSWS-QueueSize}};
                        false ->
                            <<BinToSend:MaxToSend/binary,Rest/binary>> = Stream#active_stream.queued_data,
                            {chunk_to_frames(BinToSend, MFS, Stream#active_stream.id, false, []),
                             MaxToSend,
                             Stream#active_stream{
                               queued_data=Rest,
                               send_window_size=SSWS-MaxToSend}}
                    end,


                    %h2_stream:send_data(Stream#active_stream.pid, Frame),
                    Actions = case Frames of
                                  [] ->
                                      [];
                                  _ ->
                                      [{send_data, Stream#active_stream.pid, Frames}]
                              end,
                    %sock:send(Socket, h2_frame:to_binary(Frame)),

                    {NewS1, NewActions} =
                    case NewS of
                        #active_stream{pid=Pid,
                                       queued_data=done,
                                       trailers=Trailers1} when Trailers1 /= undefined ->
                            {NewS#active_stream{trailers=undefined}, Actions ++ [{send_trailers, Pid, Trailers1}]};
                        _ ->
                            {NewS, Actions}
                    end,

                    {NewS1, {SentBytes, Stream, NewActions}}
            end;
       (Stream) ->
            {Stream, {0, Stream, []}}
    end,

    case update(StreamId, fun(Stream0) -> StreamFun(StreamFun0(Stream0)) end, Streams) of
        ok ->
            NewSWS = socket_send_window_size(Streams),
            NewSWS;
        {ok, {BytesSent, OldStream, Actions}} ->
            NewSWS = decrement_socket_send_window(BytesSent, Streams),
            case NewSWS < 0 of
                true ->
                    %% if we sent all these bytes the window would be less than 0
                    %% we delved too deep, and too greedily
                    %% try to roll things back
                    ets:insert(Streams#stream_set.table, StreamFun0(OldStream)),
                    increment_socket_send_window(BytesSent, Streams);
                false ->
                    %% ok, its now safe to apply these actions
                    apply_stream_actions(Actions),
                    NewSWS
            end
    end.

apply_stream_actions([]) ->
    ok;
apply_stream_actions([{send_data, Pid, Frames}|Tail]) ->
    [ h2_stream:send_data(Pid, Frame) || Frame <- Frames ],
    apply_stream_actions(Tail);
apply_stream_actions([{send_trailers, Pid, Trailers}]) ->
    h2_stream:send_trailers(Pid, Trailers).

chunk_to_frames(Bin, MaxFrameSize, StreamId, EndStream, Acc) when byte_size(Bin) > MaxFrameSize ->
    <<BinToSend:MaxFrameSize/binary, Rest/binary>> = Bin,
    chunk_to_frames(Rest, MaxFrameSize, StreamId, EndStream,
                    [{#frame_header{
                         stream_id=StreamId,
                         type=?DATA,
                         length=MaxFrameSize
                        },
                      h2_frame_data:new(BinToSend)}|Acc]);
chunk_to_frames(BinToSend, _MaxFrameSize, StreamId, EndStream, Acc) ->
    lists:reverse([{#frame_header{
                       stream_id=StreamId,
                       type=?DATA,
                       flags= case EndStream of
                                  true -> ?FLAG_END_STREAM;
                                  _ -> 0
                              end,
                       length=byte_size(BinToSend)
                      },
                    h2_frame_data:new(BinToSend)}|Acc]).

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

-spec stream_set_type(stream_set()) -> client | server.
stream_set_type(StreamSet) ->
    StreamSet#stream_set.type.

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

decrement_socket_recv_window(L, #stream_set{atomics = Atomics}) ->
    atomics:sub_get(Atomics, ?RECV_WINDOW_SIZE, L).

increment_socket_recv_window(L, #stream_set{atomics = Atomics}) ->
    atomics:add_get(Atomics, ?RECV_WINDOW_SIZE, L).

socket_recv_window_size(#stream_set{atomics = Atomics}) ->
    atomics:get(Atomics, ?RECV_WINDOW_SIZE).

set_socket_recv_window_size(Value, #stream_set{atomics = Atomics}) ->
    atomics:put(Atomics, ?RECV_WINDOW_SIZE, Value).

decrement_socket_send_window(L, #stream_set{atomics = Atomics}) ->
    atomics:sub_get(Atomics, ?SEND_WINDOW_SIZE, L).

increment_socket_send_window(L, #stream_set{atomics = Atomics}) ->
    atomics:add_get(Atomics, ?SEND_WINDOW_SIZE, L).

socket_send_window_size(#stream_set{atomics = Atomics}) ->
    atomics:get(Atomics, ?SEND_WINDOW_SIZE).

set_socket_send_window_size(Value, #stream_set{atomics = Atomics}) ->
    atomics:put(Atomics, ?SEND_WINDOW_SIZE, Value).


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
    atomics:get(SS#stream_set.atomics, ?MY_ACTIVE_COUNT).

%% The number of #active_stream records
-spec their_active_count(stream_set()) -> non_neg_integer().
their_active_count(SS) ->
    atomics:get(SS#stream_set.atomics, ?THEIR_ACTIVE_COUNT).

%% The list of #active_streams, and un gc'd #closed_streams
-spec my_active_streams(stream_set()) -> [stream()].
my_active_streams(SS) ->
    case SS#stream_set.type of
        client ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 1 -> S
                                                       end));
        server ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 0 -> S
                                                       end))
    end.

%% The list of #active_streams, and un gc'd #closed_streams
-spec their_active_streams(stream_set()) -> [stream()].
their_active_streams(SS) ->
    case SS#stream_set.type of
        client ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 0 -> S
                                                       end));
        server ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 1 -> S
                                                       end))
    end.

%% My MCS (max_active)
-spec my_max_active(stream_set()) -> non_neg_integer().
my_max_active(SS) ->
    (get_my_peers(SS))#peer_subset.max_active.

%% Their MCS (max_active)
-spec their_max_active(stream_set()) -> non_neg_integer().
their_max_active(SS) ->
    (get_their_peers(SS))#peer_subset.max_active.
