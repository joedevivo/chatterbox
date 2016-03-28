-module(http2_stream).

-include("http2.hrl").

%% Public API
-export([
         start_link/1,
         recv_h/2,
         send_h/2,
         send_pp/2,
         recv_es/1,
         recv_pp/2,
         recv_wu/2,
         send_frame/2,
         recv_frame/2,
         stream_id/0,
         connection/0,
         get_response/1,
         notify_pid/1,
         send_window_update/1,
         send_connection_window_update/1,
         modify_send_window_size/2,
         modify_recv_window_size/2,
         rst_stream/2
        ]).

%% gen_fsm callbacks
-behaviour(gen_fsm).
-export([
         init/1,
         terminate/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         code_change/4
        ]).

%% gen_fsm states
-export([
         idle/2,
         reserved_local/2,
         reserved_remote/2,
         open/2,
         open/3,
         half_closed_local/2,
         half_closed_remote/2,
         half_closed_remote/3,
         closed/3
        ]).

-type stream_option_name() ::
        stream_id
      | connection
      | initial_send_window_size
      | initial_recv_window_size
      | callback_module
      | notify_pid
      | socket.

-type stream_option() ::
          {stream_id, stream_id()}
        | {connection, pid()}
        | {socket, sock:socket()}
        | {initial_send_window_size, non_neg_integer()}
        | {initial_recv_window_size, non_neg_integer()}
        | {callback_module, module()}
        | {notify_pid, pid()}.

-type stream_options() ::
        [stream_option()].

-export_type([
              stream_option_name/0,
              stream_option/0,
              stream_options/0
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
          send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          incoming_frames = queue:new() :: queue:queue(frame()),
          request_headers = [] :: hpack:headers(),
          request_body :: iodata(),
          request_end_stream = false :: boolean(),
          request_end_headers = false :: boolean(),
          response_headers = [] :: hpack:headers(),
          response_body :: iodata(),
          response_end_headers = false :: boolean(),
          response_end_stream = false :: boolean(),
          next_state = undefined :: undefined | stream_state_name(),
          promised_stream = undefined :: undefined | state(),
          notify_pid = undefined :: undefined | pid(),
          callback_state = undefined :: any(),
          callback_mod = undefined :: module()
         }).

-type state() :: #stream_state{}.
-type callback_state() :: any().
-export_type([state/0, callback_state/0]).

-callback init(
            Conn :: pid(),
            StreamId :: stream_id()) ->
  {ok, callback_state()}.

-callback on_receive_request_headers(
            Headers :: hpack:headers(),
            CallbackState :: callback_state()) ->
    {ok, NewState :: callback_state()}.

-callback on_send_push_promise(
            Headers :: hpack:headers(),
            CallbackState :: callback_state()) ->
    {ok, NewState :: callback_state()}.

-callback on_receive_request_data(
            iodata(),
            CallbackState :: callback_state())->
    {ok, NewState :: callback_state()}.

-callback on_request_end_stream(
            CallbackState :: callback_state()) ->
    {ok, NewState :: callback_state()}.

%% Public API
-spec start_link(stream_options()) ->
                        {ok, pid()} | ignore | {error, term()}.
start_link(StreamOptions) ->
    gen_fsm:start_link(?MODULE, StreamOptions, []).

-spec recv_h(pid(), hpack:headers()) ->
                    ok.
recv_h(Pid, Headers) ->
    gen_fsm:send_event(Pid, {recv_h, Headers}).

-spec send_h(pid(), hpack:headers()) ->
                    ok.
send_h(Pid, Headers) ->
    gen_fsm:send_event(Pid, {send_h, Headers}).

-spec send_pp(pid(), hpack:headers()) ->
                     ok.
send_pp(Pid, Headers) ->
    gen_fsm:send_event(Pid, {send_pp, Headers}).

-spec recv_pp(pid(), hpack:headers()) ->
                     ok.
recv_pp(Pid, Headers) ->
    gen_fsm:send_event(Pid, {recv_pp, Headers}).

-spec recv_es(pid()) -> ok.
recv_es(Pid) ->
    gen_fsm:send_event(Pid, recv_es).

-spec recv_wu(pid(), {frame_header(), window_update()}) ->
                     ok | {error, flow_control}.
recv_wu(Pid, Frame) ->
    gen_fsm:sync_send_all_state_event(Pid, {recv_wu, Frame}).

-spec recv_frame(pid(), frame()) ->
                        ok.
recv_frame(Pid, Frame) ->
    gen_fsm:send_event(Pid, {recv_frame, Frame}).

-spec send_frame(pid(), frame()) ->
                        ok | flow_control.
send_frame(Pid, Frame) ->
    gen_fsm:sync_send_event(Pid, {send_frame, Frame}).

-spec stream_id() -> stream_id().
stream_id() ->
    gen_fsm:sync_send_all_state_event(self(), stream_id).

-spec connection() -> pid().
connection() ->
    gen_fsm:sync_send_all_state_event(self(), connection).

-spec get_response(pid()) ->
                          {ok, {hpack:headers(), iodata()}}
                              | {error, term()}.
get_response(Pid) ->
    gen_fsm:sync_send_event(Pid, get_response).

-spec notify_pid(pid()) ->
                          {ok, pid()}
                              | {error, term()}.
notify_pid(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, notify_pid).

-spec send_window_update(non_neg_integer()) -> ok.
send_window_update(Size) ->
    gen_fsm:send_all_state_event(self(), {send_window_update, Size}).

-spec send_connection_window_update(non_neg_integer()) -> ok.
send_connection_window_update(Size) ->
    gen_fsm:send_all_state_event(self(), {send_connection_window_update, Size}).

-spec modify_send_window_size(pid(), integer()) -> ok.
modify_send_window_size(Pid, Delta) ->
    gen_fsm:send_all_state_event(Pid, {modify_send_window_size, Delta}).

-spec modify_recv_window_size(pid(), integer()) -> ok.
modify_recv_window_size(Pid, Delta) ->
    gen_fsm:send_all_state_event(Pid, {modify_recv_window_size, Delta}).

rst_stream(Pid, Code) ->
    gen_fsm:sync_send_all_state_event(Pid, {rst_stream, Code}).

%% States
%% - idle
%% - reserved_local
%% - open
%% - half_closed_remote
%% - closed

init(StreamOptions) ->
    StreamId = proplists:get_value(stream_id, StreamOptions),
    ConnectionPid = proplists:get_value(connection, StreamOptions),
    SendWindowSize = proplists:get_value(initial_send_window_size, StreamOptions),
    RecvWindowSize = proplists:get_value(initial_recv_window_size, StreamOptions),
    CB = proplists:get_value(callback_module, StreamOptions),
    NotifyPid = proplists:get_value(notify_pid, StreamOptions, ConnectionPid),
    Socket = proplists:get_value(socket, StreamOptions),

    %% TODO: Check for CB implementing this behaviour
    {ok, CallbackState} = CB:init(ConnectionPid, StreamId),

    {ok, idle, #stream_state{
                  callback_mod=CB,
                  socket=Socket,
                  stream_id=StreamId,
                  connection=ConnectionPid,
                  send_window_size=SendWindowSize,
                  recv_window_size=RecvWindowSize,
                  callback_state=CallbackState,
                  notify_pid=NotifyPid
                 }}.

%% IMPORTANT: If we're in an idle state, we can only send/receive
%% HEADERS frames. The diagram in the spec wants you believe that you
%% can send or receive PUSH_PROMISES too, but that's a LIE. What you
%% can do is send PPs from the open or half_closed_remote state, or
%% receive them in the open or half_closed_local state. Then, that
%% will create a new stream in the idle state and THAT stream can
%% transition to one of the reserved states, but you'll never get a
%% PUSH_PROMISE frame with that Stream Id. It's a subtle thing, but it
%% drove me crazy until I figured it out

%% Server 'RECV H'
idle({recv_h, Headers},
     #stream_state{
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream) ->
    {ok, NewCBState} = CB:on_receive_request_headers(Headers, CallbackState),
    {next_state,
     open,
     Stream#stream_state{
       request_headers=Headers,
       callback_state=NewCBState
      }};
%% Server 'SEND PP'
idle({send_pp, Headers},
     #stream_state{
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream) ->
    {ok, NewCBState} = CB:on_send_push_promise(Headers, CallbackState),
    {next_state,
     reserved_local,
     Stream#stream_state{
       request_headers=Headers,
       callback_state=NewCBState
       }, 0};
       %% zero timeout lets us start dealing with reserved local,
       %% because there is no END_STREAM event

%% Client 'RECV PP'
idle({recv_pp, Headers},
     #stream_state{
       }=Stream) ->
    {next_state,
     reserved_remote,
     Stream#stream_state{
       request_headers=Headers
      }};
%% Client 'SEND H'
idle({send_h, Headers},
     #stream_state{
       }=Stream) ->
    {next_state, open,
     Stream#stream_state{
        request_headers=Headers
       }};
idle(Message, State) ->
    lager:error("stream idle processing unexpected message: ~p", [Message]),
    %% Never should happen.
    {next_state, idle, State}.

reserved_local(timeout,
               #stream_state{
                  callback_state=CallbackState,
                  callback_mod=CB
                  }=Stream) ->
    {ok, NewCBState} = CB:on_request_end_stream(CallbackState),
    {next_state,
     reserved_local,
     Stream#stream_state{
       callback_state=NewCBState
      }};
reserved_local({send_h, Headers},
              #stream_state{
                }=Stream) ->
    {next_state,
     half_closed_remote,
     Stream#stream_state{
       response_headers=Headers
      }}.

reserved_remote({recv_h, Headers},
               #stream_state{
                 }=Stream) ->
    {next_state,
     half_closed_local,
     Stream#stream_state{
       response_headers=Headers
      }}.

open(recv_es,
     #stream_state{
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream) ->
    {ok, NewCBState} = CB:on_request_end_stream(CallbackState),
    {next_state,
     half_closed_remote,
     Stream#stream_state{
       callback_state=NewCBState
      }};

%% Open receive data frame that is larger than the stream's recv_window_size
open({recv_frame,
      {#frame_header{
         length=L,
         type=?DATA
         },_}},
     #stream_state{
        recv_window_size=RWS
       }=Stream)
  when RWS < L ->
    rst_stream_(?FLOW_CONTROL_ERROR, Stream),
    {next_state,
     closed,
     Stream};

open({recv_frame,
      {#frame_header{
          length=L,
          flags=Flags,
          type=?DATA
         },_}=F},
     #stream_state{
        incoming_frames=IFQ,
        recv_window_size=SRWS,
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream)
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    {ok, NewCBState} = CB:on_receive_request_data(F, CallbackState),
    {next_state,
     open,
     Stream#stream_state{
       %% TODO: We're storing everything in the state. It's fine for
       %% some cases, but the decision should be left to the user
       incoming_frames=queue:in(F, IFQ),
       recv_window_size=SRWS-L,
       callback_state=NewCBState
      }};
open({recv_frame,
      {#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
         }, _Payload}=F},
     #stream_state{
        incoming_frames=IFQ,
        recv_window_size=SRWS,
        callback_mod=CB,
        callback_state=CallbackState
       }=Stream)
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    {ok, CallbackState1} = CB:on_receive_request_data(F, CallbackState),
    {ok, NewCBState} = CB:on_request_end_stream(CallbackState1),
    {next_state,
     half_closed_remote,
     Stream#stream_state{
       incoming_frames=queue:in(F, IFQ),
       recv_window_size=SRWS-L,
       request_end_stream=true,
       callback_state=NewCBState
      }};
open(Msg, Stream) ->
    lager:warning("Some unexpected message in open state. ~p, ~p", [Msg, Stream]),
    {next_state, open, Stream}.

%% TODO: Abstract sending data into one function that does flow
%% control math and replies either 'ok' or 'flow_control'
open({send_frame,
      {#frame_header{
          type=?DATA,
          length=L
         }, _}=_F},
     _From,
     #stream_state{
        send_window_size=SWS
       }=Stream)
  when L > SWS ->
    {reply, flow_control, open, Stream};
open({send_frame,
      {#frame_header{
          type=?DATA,
          flags=Flags,
          length=L
         }, _}=F},
     _From,
     #stream_state{
        socket=Socket,
        send_window_size=SWS
       }=Stream) ->
    sock:send(Socket, http2_frame:to_binary(F)),

    NextState =
        case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
            true ->
                half_closed_local;
            _ ->
                open
        end,
    {reply, ok, NextState,
     Stream#stream_state{send_window_size=SWS-L}}.

half_closed_remote(
  {send_h, Headers},
  #stream_state{}=Stream) ->
    {next_state,
     half_closed_remote,
     Stream#stream_state{
       response_headers=Headers
      }}.

half_closed_remote(
                  {send_frame,
                   {
                     #frame_header{
                        type=?DATA,
                        length=L
                       },_
                   }}=_Msg,
  _From,
  #stream_state{
     send_window_size=SWS
    }=Stream)
  when L > SWS ->
    {reply, flow_control, half_closed_remote, Stream};
half_closed_remote(
                  {send_frame,
                   {
                     #frame_header{
                        flags=Flags,
                        type=?DATA,
                        length=L
                       },_
                   }=F}=_Msg,
  _From,
  #stream_state{
     socket=Socket,
     send_window_size=SWS
    }=Stream) ->
    ok = sock:send(Socket, http2_frame:to_binary(F)),

    NextState =
        case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
            true ->
                %lager:error("half_closed remote -> closed ~p",
                %            [Stream#stream_state.stream_id]),
                closed;
        _ ->
                half_closed_remote
        end,

    {reply, ok, NextState,
     Stream#stream_state{send_window_size=SWS-L}}.

%% PUSH_PROMISES can only be received by streams in the open or
%% half_closed_local, but will create a new stream in the idle state,
%% but that stream may be ready to transition, it'll make sense, I
%% hope!
half_closed_local(
  {recv_h, Headers},
  #stream_state{
    }=Stream) ->
    {next_state,
     half_closed_local,
     Stream#stream_state{
       response_headers=Headers}};
half_closed_local(
  {recv_frame,
   {#frame_header{
       flags=Flags,
       type=?DATA
      },_}=F},
  #stream_state{
     stream_id=StreamId,
     incoming_frames=IFQ,
     notify_pid = NotifyPid
     } = Stream) ->
    NewQ = queue:in(F, IFQ),

    case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
        true ->
            Data = [ D || {#frame_header{type=?DATA}, #data{data=D}} <- queue:to_list(NewQ)],
            case NotifyPid of
                undefined ->
                    ok;
                _ ->
                    NotifyPid ! {'END_STREAM', StreamId}
            end,
            {next_state, closed,
             Stream#stream_state{
               incoming_frames=queue:new(),
               response_body = Data
              }};
        _ ->
            {next_state,
             half_closed_local,
             Stream#stream_state{
               incoming_frames=NewQ
              }}
    end.

closed(get_response,
       _From,
       #stream_state{
          response_headers=H,
          response_body=B
         }=Stream
       ) ->
    {reply, {ok, {H, B}}, closed, Stream}.

handle_event({modify_send_window_size, Delta},
            StateName,
             #stream_state{
                send_window_size=SWS
               }=Stream
            ) ->
    {next_state, StateName,
     Stream#stream_state{
       send_window_size=SWS - Delta
      }};
handle_event({modify_recv_window_size, Delta},
            StateName,
             #stream_state{
                recv_window_size=RWS
               }=Stream
            ) ->
    {next_state, StateName,
     Stream#stream_state{
       recv_window_size=RWS - Delta
      }};
handle_event({send_window_update, 0},
             StateName,
             #stream_state{}=Stream) ->
    {next_state, StateName, Stream};
handle_event({send_window_update, Size},
             StateName,
             #stream_state{
                socket=Socket,
                stream_id=StreamId,
                recv_window_size=RWS
               }=Stream) ->
    http2_frame_window_update:send(Socket, Size, StreamId),
    {next_state, StateName,
     Stream#stream_state{
       recv_window_size=RWS+Size
       }};
handle_event({send_connection_window_update, Size},
             StateName,
             #stream_state{
                connection=ConnPid
               }=State) ->
    http2_connection:send_window_update(ConnPid, Size),
    {next_state, StateName, State};
handle_event(_E, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event({recv_wu,
              {#frame_header{
                  type=?WINDOW_UPDATE,
                  stream_id=StreamId
                 },
               #window_update{
                  window_size_increment=WSI
                 }
              }},
                  _F,
                  StateName,
              #stream_state{
                 stream_id=StreamId,
                 send_window_size=SWS
                }=Stream)
             ->
    NewSendWindow = WSI + SWS,
    case NewSendWindow > 2147483647 of
        true ->
            lager:error("Sending ~p FLOWCONTROL ERROR because NSW = ~p", [StreamId, NewSendWindow]),
            rst_stream_(?FLOW_CONTROL_ERROR, Stream),
            {reply, {error, flow_control}, closed, Stream};
        false ->
            NewStream = Stream#stream_state{
                          send_window_size=NewSendWindow
                         },
            lager:debug("Stream ~p send window now: ~p", [StreamId, NewSendWindow]),
            {reply, ok, StateName, NewStream}
    end;


handle_sync_event({rst_stream, ErrorCode}, _F, StateName, State=#stream_state{}) ->
    {reply, {ok, rst_stream_(ErrorCode, State)}, StateName, State};
handle_sync_event(notify_pid, _F, StateName, State=#stream_state{notify_pid=NP}) ->
    {reply, {ok,NP}, StateName, State};
handle_sync_event(stream_id, _F, StateName, State=#stream_state{stream_id=StreamId}) ->
    {reply, StreamId, StateName, State};
handle_sync_event(connection, _F, StateName, State=#stream_state{connection=Conn}) ->
    {reply, Conn, StateName, State};
handle_sync_event(_E, _F, StateName, State) ->
    {reply, wat, StateName, State}.

handle_info(M, _StateName, State) ->
    lager:error("BOOM! ~p", [M]),
    {stop, normal, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    lager:debug("terminate reason: ~p~n", [_Reason]).

-spec rst_stream_(error_code(), state()) -> ok.
rst_stream_(ErrorCode,
           #stream_state{
              socket=Socket,
              stream_id=StreamId
              }
          ) ->
    RstStream = #rst_stream{error_code=ErrorCode},
    RstStreamBin = http2_frame:to_binary(
                     {#frame_header{
                         stream_id=StreamId
                        },
                      RstStream}),
    sock:send(Socket, RstStreamBin),
    ok.
