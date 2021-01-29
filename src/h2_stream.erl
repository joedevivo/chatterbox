-module(h2_stream).
-include("http2.hrl").

%% Public API
-export([
         start_link/6,
         send_event/2,
         send_pp/2,
         send_data/2,
         send_trailers/2,
         stream_id/0,
         call/2,
         connection/0,
         send_window_update/1,
         send_connection_window_update/1,
         rst_stream/2,
         stop/1
        ]).

%% gen_statem callbacks
-behaviour(gen_statem).

-export([init/1,
         callback_mode/0,
         terminate/3,
         code_change/4]).

%% gen_statem states
-export([
         idle/3,
         reserved_local/3,
         reserved_remote/3,
         open/3,
         half_closed_local/3,
         half_closed_remote/3,
         closed/3
        ]).

-type stream_state_name() :: 'idle'
                           | 'open'
                           | 'closed'
                           | 'reserved_local'
                           | 'reserved_remote'
                           | 'half_closed_local'
                           | 'half_closed_remote'.

-record(stream_state, {
          stream_id = undefined :: stream_id(),
          connection = undefined :: undefined | pid(),
          socket = undefined :: sock:socket(),
          state = idle :: stream_state_name(),
          incoming_frames = queue:new() :: queue:queue(h2_frame:frame()),
          request_headers = [] :: hpack:headers(),
          request_body :: iodata() | undefined,
          request_body_size = 0 :: non_neg_integer(),
          request_end_stream = false :: boolean(),
          request_end_headers = false :: boolean(),
          response_headers = [] :: hpack:headers(),
          response_trailers = [] :: hpack:headers(),
          response_body = undefined :: iodata() | undefined,
          response_end_headers = false :: boolean(),
          response_end_stream = false :: boolean(),
          next_state = undefined :: undefined | stream_state_name(),
          promised_stream = undefined :: undefined | state(),
          callback_state = undefined :: any(),
          callback_mod = undefined :: module(),
          type :: client | server
         }).

-type state() :: #stream_state{}.
-type callback_state() :: any().
-export_type([state/0, callback_state/0]).

-callback init(
            Conn :: pid(),
            StreamId :: stream_id(),
            CallbackOptions :: list()
           ) ->
  {ok, callback_state()}.

-callback on_receive_headers(
            Headers :: hpack:headers(),
            CallbackState :: callback_state()) ->
    {ok, NewState :: callback_state()}.

-callback on_send_push_promise(
            Headers :: hpack:headers(),
            CallbackState :: callback_state()) ->
    {ok, NewState :: callback_state()}.

-callback on_receive_data(
            iodata(),
            CallbackState :: callback_state())->
    {ok, NewState :: callback_state()}.

-callback on_end_stream(
            CallbackState :: callback_state()) ->
    {ok, NewState :: callback_state()}.

%% Public API
-spec start_link(
        StreamId :: stream_id(),
        Connection :: pid(),
        CallbackModule :: module(),
        CallbackOptions :: list(),
        Type :: client | server,
        Socket :: sock:socket()
                  ) ->
                        {ok, pid()} | ignore | {error, term()}.
start_link(StreamId, Connection, CallbackModule, CallbackOptions, Type, Socket) ->
    gen_statem:start_link(?MODULE,
                          [StreamId,
                           Connection,
                           CallbackModule,
                           CallbackOptions,
                           Type,
                           Socket],
                          []).

send_event(Pid, Event) ->
    gen_statem:cast(Pid, Event).

-spec send_pp(pid(), hpack:headers()) ->
                     ok.
send_pp(Pid, Headers) ->
    gen_statem:cast(Pid, {send_pp, Headers}).

-spec send_data(pid(), h2_frame_data:frame()) ->
                        ok | flow_control.
send_data(Pid, Frame) ->
    gen_statem:cast(Pid, {send_data, Frame}).

-spec send_trailers(pid(), hpack:headers()) -> ok.
send_trailers(Pid, Trailers) ->
    gen_statem:cast(Pid, {send_trailers, Trailers}),
    ok.

-spec stream_id() -> stream_id().
stream_id() ->
    gen_statem:call(self(), stream_id).

call(Pid, Msg) ->
    gen_statem:call(Pid, Msg).

-spec connection() -> pid().
connection() ->
    gen_statem:call(self(), connection).

-spec send_window_update(non_neg_integer()) -> ok.
send_window_update(Size) ->
    gen_statem:cast(self(), {send_window_update, Size}).

-spec send_connection_window_update(non_neg_integer()) -> ok.
send_connection_window_update(Size) ->
    gen_statem:cast(self(), {send_connection_window_update, Size}).

rst_stream(Pid, Code) ->
    gen_statem:call(Pid, {rst_stream, Code}).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid).

init([
      StreamId,
      ConnectionPid,
      CB=undefined,
      _CBOptions,
      Type,
      Socket
     ]) ->
    {ok, idle, #stream_state{
                  callback_mod=CB,
                  socket=Socket,
                  stream_id=StreamId,
                  connection=ConnectionPid,
                  type = Type
                 }};
init([
      StreamId,
      ConnectionPid,
      CB,
      CBOptions,
      Type,
      Socket
     ]) ->
    %% TODO: Check for CB implementing this behaviour
    {ok, NewCBState} = callback(CB, init, [ConnectionPid, StreamId], [Socket | CBOptions]),
    {ok, idle, #stream_state{
                  callback_mod=CB,
                  socket=Socket,
                  stream_id=StreamId,
                  connection=ConnectionPid,
                  callback_state=NewCBState,
                  type = Type
                 }}.

callback_mode() ->
    state_functions.

%% IMPORTANT: If we're in an idle state, we can only send/receive
%% HEADERS frames. The diagram in the spec wants you believe that you
%% can send or receive PUSH_PROMISES too, but that's a LIE. What you
%% can do is send PPs from the open or half_closed_remote state, or
%% receive them in the open or half_closed_local state. Then, that
%% will create a new stream in the idle state and THAT stream can
%% transition to one of the reserved states, but you'll never get a
%% PUSH_PROMISE frame with that Stream Id. It's a subtle thing, but it
%% drove me crazy until I figured it out

callback(undefined, _, _, State) ->
    {ok, State};
callback(Mod, Fun, Args, State) ->
    %% load the module if it isn't already
    AllArgs = Args ++ [State],
    erlang:function_exported(Mod, module_info, 0) orelse code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, Fun, length(AllArgs)) of
        true ->
            erlang:apply(Mod, Fun, AllArgs);
        false ->
            {ok, State}
    end.

%% Server 'RECV H'
idle(cast, {recv_h, Headers},
     #stream_state{
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream) ->
    case is_valid_headers(request, Headers) of
        ok ->
            {ok, NewCBState} = callback(CB, on_receive_headers, [Headers], CallbackState),
            {next_state,
             open,
             Stream#stream_state{
               request_headers=Headers,
               callback_state=NewCBState
              }};
        {error, Code} ->
            rst_stream_(Code, Stream)
    end;

%% Server 'SEND PP'
idle(cast, {send_pp, Headers},
     #stream_state{
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream) ->
    {ok, NewCBState} = callback(CB, on_send_push_promise, [Headers], CallbackState),
    {next_state,
     reserved_local,
     Stream#stream_state{
       request_headers=Headers,
       callback_state=NewCBState
       }, 0};
       %% zero timeout lets us start dealing with reserved local,
       %% because there is no END_STREAM event

%% Client 'RECV PP'
idle(cast, {recv_pp, Headers},
     #stream_state{
       }=Stream) ->
    {next_state,
     reserved_remote,
     Stream#stream_state{
       request_headers=Headers
      }};
%% Client 'SEND H'
idle(cast, {send_h, Headers},
     #stream_state{
       }=Stream) ->
    {next_state, open,
     Stream#stream_state{
        request_headers=Headers
       }};
idle(Type, Event, State) ->
    handle_event(Type, Event, State).

reserved_local(timeout, _,
               #stream_state{
                  callback_state=CallbackState,
                  callback_mod=CB
                  }=Stream) ->
    check_content_length(Stream),
    {ok, NewCBState} = callback(CB, on_end_stream, [], CallbackState),
    {next_state,
     reserved_local,
     Stream#stream_state{
       callback_state=NewCBState
      }};
reserved_local(cast, {send_h, Headers},
              #stream_state{
                }=Stream) ->
    {next_state,
     half_closed_remote,
     Stream#stream_state{
       response_headers=Headers
      }};
reserved_local(cast, {send_t, Headers},
              #stream_state{
                }=Stream) ->
    {keep_state,
     Stream#stream_state{
       response_trailers=Headers
      }};
reserved_local(Type, Event, State) ->
    handle_event(Type, Event, State).

reserved_remote(cast, {recv_h, Headers},
                #stream_state{
                   callback_mod=CB,
                   callback_state=CallbackState
                  }=Stream) ->
    {ok, NewCBState} = callback(CB, on_receive_headers, [Headers], CallbackState),
    {next_state,
     half_closed_local,
     Stream#stream_state{
       response_headers=Headers,
       callback_state=NewCBState
      }};
reserved_remote(cast, {recv_t, Headers},
                #stream_state{
                   callback_mod=CB,
                   callback_state=CallbackState
                  }=Stream) ->
    {ok, NewCBState} = callback(CB, on_receive_headers, [Headers], CallbackState),
    {next_state,
     half_closed_local,
     Stream#stream_state{
       response_headers=Headers,
       callback_state=NewCBState
      }};
reserved_remote(Type, Event, State) ->
    handle_event(Type, Event, State).

open(cast, recv_es,
     #stream_state{
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream) ->
    case check_content_length(Stream) of
        ok ->
            {ok, NewCBState} = callback(CB, on_end_stream, [], CallbackState),
            {next_state,
             half_closed_remote,
             Stream#stream_state{
               callback_state=NewCBState
              }};
        rst_stream ->
            {next_state,
             closed,
             Stream}
    end;

open(cast, {recv_data,
      {#frame_header{
          flags=Flags,
          length=L,
          type=?DATA
         }, Payload}=F},
     #stream_state{
        incoming_frames=IFQ,
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream)
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    Bin = h2_frame_data:data(Payload),
    case CB of
        undefined ->
            {next_state,
             open,
             Stream#stream_state{
               %% TODO: We're storing everything in the state. It's fine for
               %% some cases, but the decision should be left to the user
               incoming_frames=queue:in(F, IFQ),
               request_body_size=Stream#stream_state.request_body_size+L
              }};
        _ ->
            {ok, NewCBState} = callback(CB, on_receive_data, [Bin], CallbackState),
            {next_state,
             open,
             Stream#stream_state{
               request_body_size=Stream#stream_state.request_body_size+L,
               callback_state=NewCBState
              }}
    end;
open(cast, {recv_data,
      {#frame_header{
          flags=Flags,
          length=L,
          type=?DATA
         }, Payload}=F},
     #stream_state{
        incoming_frames=IFQ,
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream)
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    Bin = h2_frame_data:data(Payload),
    case CB of
        undefined ->
            NewStream =
                Stream#stream_state{
                  incoming_frames=queue:in(F, IFQ),
                  request_body_size=Stream#stream_state.request_body_size+L,
                  request_end_stream=true
                 },
            case check_content_length(NewStream) of
                ok ->
                    {next_state, half_closed_remote, NewStream};
                rst_stream ->
                    {next_state, closed, NewStream}
            end;

        _ ->
            {ok, NewCBState} = callback(CB, on_receive_data, [Bin], CallbackState),

            NewStream = Stream#stream_state{
                          request_body_size=Stream#stream_state.request_body_size+L,
                          request_end_stream=true,
                          callback_state=NewCBState
                         },
            case check_content_length(NewStream) of
                ok ->
                    {ok, NewCBState1} = callback(CB, on_end_stream, [], NewCBState),
                    {next_state,
                     half_closed_remote,
                     NewStream#stream_state{
                       callback_state=NewCBState1
                      }};
                rst_stream ->
                    {next_state,
                     closed,
                     NewStream}
            end
    end;

%% Trailers
open(cast, {recv_h, Trailers},
     #stream_state{type=server}=Stream) ->
    case is_valid_headers(request, Trailers) of
        ok ->
            {keep_state,
             Stream#stream_state{
               request_headers=Stream#stream_state.request_headers ++ Trailers
              }};
        {error, Code} ->
            rst_stream_(Code, Stream)
    end;
open(cast, {recv_h, Headers},
     #stream_state{type=client,
                   callback_mod=CB,
                   callback_state=CallbackState}=Stream) ->
  case is_valid_headers(response, Headers) of
      ok ->
          {ok, NewCBState} = callback(CB, on_receive_headers, [Headers], CallbackState),
          {keep_state,
           Stream#stream_state{
             callback_state=NewCBState,
             response_headers=Headers}};
      {error, Code} ->
          rst_stream_(Code, Stream)
  end;
open(cast, {send_data,
      {#frame_header{
          type=?HEADERS,
          flags=Flags
         }, _}=F},
     #stream_state{
        socket=Socket
       }=Stream) ->
    sock:send(Socket, h2_frame:to_binary(F)),

    NextState =
        case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
            true ->
                half_closed_local;
            _ ->
                open
        end,
    {next_state, NextState, Stream};
open(cast, {send_data,
      {#frame_header{
          type=?DATA,
          flags=Flags
         }, _}=F},
     #stream_state{
        socket=Socket
       }=Stream) ->
    sock:send(Socket, h2_frame:to_binary(F)),

    NextState =
        case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
            true ->
                half_closed_local;
            _ ->
                open
        end,
    {next_state, NextState, Stream};
open(_, {send_trailers, Trailers}, Stream) ->
    send_trailers(open, Trailers, Stream);
open(cast,
  {send_h, Headers},
  #stream_state{}=Stream) ->
    {next_state,
     open,
     Stream#stream_state{
       response_headers=Headers
      }};
open(cast,
  {send_t, Headers},
  #stream_state{}=Stream) ->
    {keep_state,
     Stream#stream_state{
       response_trailers=Headers
      }};
open(Type, Event, State) ->
    handle_event(Type, Event, State).


half_closed_remote(cast,
  {send_h, Headers},
  #stream_state{}=Stream) ->
    {next_state,
     half_closed_remote,
     Stream#stream_state{
       response_headers=Headers
      }};
half_closed_remote(cast,
  {send_t, Headers},
  #stream_state{}=Stream) ->
    {keep_state,
     Stream#stream_state{
       response_trailers=Headers
      }};
half_closed_remote(cast,
                  {send_data,
                   {
                     #frame_header{
                        flags=Flags,
                        type=?DATA
                       },_
                   }=F}=_Msg,
  #stream_state{
     socket=Socket
    }=Stream) ->
    case sock:send(Socket, h2_frame:to_binary(F)) of
        ok ->
            case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
                true ->
                    {next_state, closed, Stream, 0};
                _ ->
                    {next_state, half_closed_remote, Stream}
            end;
        {error,_} ->
            {next_state, closed, Stream, 0}
    end;
half_closed_remote(cast,
                  {send_data,
                   {
                     #frame_header{
                        flags=Flags,
                        type=?HEADERS
                       },_
                   }=F}=_Msg,
  #stream_state{
     socket=Socket
    }=Stream) ->
    case sock:send(Socket, h2_frame:to_binary(F)) of
        ok ->
            case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
                true ->
                    {next_state, closed, Stream, 0};
                _ ->
                    {next_state, half_closed_remote, Stream}
            end;
        {error,_} ->
            {next_state, closed, Stream, 0}
    end;

half_closed_remote(_Type, {send_trailers, Trailers}, State) ->
    send_trailers(half_closed_remote, Trailers, State);
half_closed_remote(cast, _,
       #stream_state{}=Stream) ->
    rst_stream_(?STREAM_CLOSED, Stream);
half_closed_remote(Type, Event, State) ->
    handle_event(Type, Event, State).

%% PUSH_PROMISES can only be received by streams in the open or
%% half_closed_local, but will create a new stream in the idle state,
%% but that stream may be ready to transition, it'll make sense, I
%% hope!
half_closed_local(cast,
                  {recv_h, Headers},
                  #stream_state{callback_mod=CB,
                                callback_state=CallbackState
                               }=Stream) ->
  case is_valid_headers(response, Headers) of
      ok ->
          {ok, NewCBState} = callback(CB, on_receive_headers, [Headers], CallbackState),
          {next_state,
           half_closed_local,
           Stream#stream_state{
             callback_state=NewCBState,
             response_headers=Headers}};
      {error, Code} ->
          rst_stream_(Code, Stream)
  end;

half_closed_local(cast,
  {recv_data,
   {#frame_header{
       flags=Flags,
       type=?DATA
      }, _}=F},
  #stream_state{
     callback_mod=undefined,
     incoming_frames=IFQ
     } = Stream) ->
    NewQ = queue:in(F, IFQ),
    case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
        true ->
            Data =
                [h2_frame_data:data(Payload)
                 || {#frame_header{type=?DATA}, Payload} <- queue:to_list(NewQ)],
            {next_state, closed,
             Stream#stream_state{
               incoming_frames=queue:new(),
               response_body = Data
              }, 0};
        _ ->
            {next_state,
             half_closed_local,
             Stream#stream_state{
               incoming_frames=NewQ
              }}
    end;
half_closed_local(cast,
  {recv_data,
   {#frame_header{
       flags=Flags,
       type=?DATA
      }, Payload}},
  #stream_state{
     callback_mod=CB,
     callback_state=CallbackState
     } = Stream) ->
    Data = h2_frame_data:data(Payload),
    {ok, NewCBState} = callback(CB, on_receive_data, [Data], CallbackState),
    case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
        true ->
            {ok, NewCBState1} = callback(CB, on_end_stream, [], NewCBState),
            {next_state, closed,
             Stream#stream_state{
               callback_state=NewCBState1
              }, 0};
        _ ->
            {next_state,
             half_closed_local,
             Stream#stream_state{
               callback_state=NewCBState
              }}
    end;
half_closed_local(cast, recv_es,
                  #stream_state{
                     response_body = undefined,
                     callback_mod=CB,
                     callback_state=CallbackState,
                     incoming_frames = Q
                    } = Stream) ->
    {ok, NewCBState} = callback(CB, on_end_stream, [], CallbackState),
    Data = [h2_frame_data:data(Payload) || {#frame_header{type=?DATA}, Payload} <- queue:to_list(Q)],
    {next_state, closed,
     Stream#stream_state{
       incoming_frames=queue:new(),
       response_body = Data,
       callback_state=NewCBState
      }, 0};

half_closed_local(cast, recv_es,
                  #stream_state{
                     response_body = Data,
                     callback_mod=CB,
                     callback_state=CallbackState
                    } = Stream) ->
    {ok, NewCBState} = callback(CB, on_end_stream, [], CallbackState),
    {next_state, closed,
     Stream#stream_state{
       incoming_frames=queue:new(),
       response_body = Data,
       callback_state=NewCBState
      }, 0};
half_closed_local(cast, {send_t, _Trailers},
                  #stream_state{}) ->
    keep_state_and_data;
half_closed_local(_, _,
       #stream_state{}=Stream) ->
    rst_stream_(?STREAM_CLOSED, Stream);
half_closed_local(Type, Event, State) ->
    handle_event(Type, Event, State).

closed(timeout, _,
       #stream_state{}=Stream) ->
    gen_statem:cast(Stream#stream_state.connection,
                    {stream_finished,
                     Stream#stream_state.stream_id,
                     Stream#stream_state.response_headers,
                     Stream#stream_state.response_body,
                     Stream#stream_state.response_trailers}),
    {stop, normal, Stream};
closed(_, _,
       #stream_state{}=Stream) ->
    rst_stream_(?STREAM_CLOSED, Stream);
closed(Type, Event, State) ->
    handle_event(Type, Event, State).

send_trailers(State, Trailers, Stream=#stream_state{connection=Pid,
                                                    stream_id=StreamId}) ->
    h2_connection:actually_send_trailers(Pid, StreamId, Trailers),
    case State of
        half_closed_remote ->
            {next_state, closed, Stream};
        open ->
            {next_state, half_closed_local, Stream}
    end.

handle_event(_, {send_window_update, 0},
             #stream_state{}=Stream) ->
    {keep_state, Stream};
handle_event(_, {send_window_update, Size},
             #stream_state{
               socket=Socket,
               stream_id=StreamId
              }=Stream) ->
    h2_frame_window_update:send(Socket, Size, StreamId),
    {keep_state, Stream#stream_state{}};
handle_event(_, {send_connection_window_update, Size},
             #stream_state{
                  connection=ConnPid
                 }=State) ->
    h2_connection:send_window_update(ConnPid, Size),
    {keep_state, State};
handle_event({call,  From}, {rst_stream, ErrorCode}, State=#stream_state{}) ->
    {keep_state, State, [{reply, From, {ok, rst_stream_(ErrorCode, State)}}]};
handle_event({call, From}, stream_id, State=#stream_state{stream_id=StreamId}) ->
    {keep_state, State, [{reply, From, StreamId}]};
handle_event({call, From}, connection, State=#stream_state{connection=Conn}) ->
    {keep_state, State, [{reply, From, Conn}]};
handle_event({call, From}, Event, State=#stream_state{callback_mod=CB,
                                                      callback_state=CallbackState}) ->
    {ok, Reply, CallbackState1} = CB:handle_call(Event, CallbackState),
    {keep_state, State#stream_state{callback_state=CallbackState1}, [{reply, From, Reply}]};
handle_event(cast, Event, State=#stream_state{callback_mod=CB,
                                              callback_state=CallbackState}) ->
    CallbackState1 = CB:handle_info(Event, CallbackState),
    {keep_state, State#stream_state{callback_state=CallbackState1}};
handle_event(info, Event, State=#stream_state{callback_mod=CB,
                                              callback_state=CallbackState}) ->
     CallbackState1 = CB:handle_info(Event, CallbackState),
    {keep_state, State#stream_state{callback_state=CallbackState1}};
handle_event(_, _Event, State) ->
     {keep_state, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    ok.

-spec rst_stream_(error_code(), state()) ->
                         {next_state,
                          closed,
                          state(),
                          timeout()}.
rst_stream_(ErrorCode,
           #stream_state{
              socket=Socket,
              stream_id=StreamId
              }=Stream
          )
            ->
    RstStream = h2_frame_rst_stream:new(ErrorCode),
    RstStreamBin = h2_frame:to_binary(
                  {#frame_header{
                      stream_id=StreamId
                     },
                   RstStream}),
    sock:send(Socket, RstStreamBin),
    {next_state,
     closed,
     Stream, 0}.

check_content_length(Stream) ->
    ContentLength =
        proplists:get_value(<<"content-length">>,
                            Stream#stream_state.request_headers),

    case ContentLength of
        undefined ->
            ok;
        _Other ->
            try binary_to_integer(ContentLength) of
                Integer ->
                    case Stream#stream_state.request_body_size =:= Integer of
                        true ->
                            ok;
                        false ->
                            rst_stream_(?PROTOCOL_ERROR, Stream),
                            rst_stream
                    end
            catch
                _:_ ->
                    rst_stream_(?PROTOCOL_ERROR, Stream),
                    rst_stream
            end
    end.


%%% Moving header validation into streams

%% Function checks if a set of headers is valid. Currently that means:
%%
%% * The list of acceptable pseudoheaders for requests are:
%%      :method, :scheme, :authority, :path,
%% * The only acceptable pseudoheader for responses is :status
%% * All header names are lowercase.
%% * All pseudoheaders occur before normal headers.
%% * No pseudoheaders are duplicated

-spec is_valid_headers( request | response,
                        hpack:headers() ) ->
                              ok | {error, term()}.
is_valid_headers(Type, Headers) ->
    case
        validate_pseudos(Type, Headers)
    of
        true ->
            ok;
        false ->
            {error, ?PROTOCOL_ERROR}
    end.

no_upper_names(Headers) ->
    lists:all(
      fun({Name,_}) ->
              NameStr = binary_to_list(Name),
              NameStr =:= string:to_lower(NameStr)
      end,
     Headers).

validate_pseudos(Type, Headers) ->
    validate_pseudos(Type, Headers, #{}).

validate_pseudos(request, [{<<":path">>,_V}|_Tail], #{<<":path">> := true }) ->
    false;
validate_pseudos(request, [{<<":path">>,_V}|Tail], Found) ->
    validate_pseudos(request, Tail, Found#{<<":path">> => true});
validate_pseudos(request, [{<<":method">>,_V}|_Tail], #{<<":method">> := true }) ->
    false;
validate_pseudos(request, [{<<":method">>,_V}|Tail], Found) ->
    validate_pseudos(request, Tail, Found#{<<":method">> => true});
validate_pseudos(request, [{<<":scheme">>,_V}|_Tail], #{<<":scheme">> := true }) ->
    false;
validate_pseudos(request, [{<<":scheme">>,_V}|Tail], Found) ->
    validate_pseudos(request, Tail, Found#{<<":scheme">> => true});
validate_pseudos(request, [{<<":authority">>,_V}|_Tail], #{<<":authority">> := true }) ->
    false;
validate_pseudos(request, [{<<":authority">>,_V}|Tail], Found) ->
    validate_pseudos(request, Tail, Found#{<<":authority">> => true});
validate_pseudos(response, [{<<":status">>,_V}|_Tail], #{<<":status">> := true }) ->
    false;
validate_pseudos(response, [{<<":status">>,_V}|Tail], Found) ->
    validate_pseudos(response, Tail, Found#{<<":status">> => true});
validate_pseudos(_, DoneWithPseudos, _Found) ->
    lists:all(
      fun({<<$:, _/binary>>, _}) ->
              false;
         ({<<"connection">>, _}) ->
              false;
         ({<<"te">>, <<"trailers">>}) ->
              true;
         ({<<"te">>, _}) ->
              false;
         (_) -> true
      end,
      DoneWithPseudos)
        andalso
        no_upper_names(DoneWithPseudos).
