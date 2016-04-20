-module(http2_stream).

-include("http2.hrl").
-include("h2_streams.hrl").

%% Public API
-export([
         start_link/1,
         send_h/2,
         send_pp/2,
         recv_es/1,
         recv_pp/2,
         send_frame/2,
         recv_frame/2,
         stream_id/0,
         connection/0,
         notify_pid/1,
         send_window_update/1,
         send_connection_window_update/1,
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
         half_closed_local/2,
         half_closed_remote/2,
         closed/2
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
          incoming_frames = queue:new() :: queue:queue(http2_frame:frame()),
          request_headers = [] :: hpack:headers(),
          request_body :: iodata(),
          request_body_size = 0 :: non_neg_integer(),
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

-spec recv_es(stream()) ->
                     ok | {rst_stream, error_code()}.

recv_es(#closed_stream{}) ->
    {rst_stream, ?STREAM_CLOSED};
recv_es(#active_stream{pid=undefined}) ->
    {rst_stream, ?STREAM_CLOSED};
recv_es(#active_stream{pid=Pid}) ->
    gen_fsm:send_event(Pid, recv_es).

-spec recv_frame(pid(), http2_frame:frame()) ->
                        ok.
recv_frame(Pid, Frame) ->
    gen_fsm:send_event(Pid, {recv_frame, Frame}).

-spec send_frame(pid(), http2_frame:frame()) ->
                        ok | flow_control.
send_frame(Pid, Frame) ->
    gen_fsm:send_event(Pid, {send_frame, Frame}).

-spec stream_id() -> stream_id().
stream_id() ->
    gen_fsm:sync_send_all_state_event(self(), stream_id).

-spec connection() -> pid().
connection() ->
    gen_fsm:sync_send_all_state_event(self(), connection).

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
    case is_valid_headers(request, Headers) of
        ok ->
            {ok, NewCBState} = CB:on_receive_request_headers(Headers, CallbackState),
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
    check_content_length(Stream),
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
    case check_content_length(Stream) of
        ok ->
            {ok, NewCBState} = CB:on_request_end_stream(CallbackState),
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

open({recv_frame,
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
    Bin = http2_frame_data:data(Payload),
    {ok, NewCBState} = CB:on_receive_request_data(Bin, CallbackState),
    {next_state,
     open,
     Stream#stream_state{
       %% TODO: We're storing everything in the state. It's fine for
       %% some cases, but the decision should be left to the user
       incoming_frames=queue:in(F, IFQ),
       request_body_size=Stream#stream_state.request_body_size+L,
       callback_state=NewCBState
      }};
open({recv_frame,
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
    Bin = http2_frame_data:data(Payload),
    {ok, CallbackState1} = CB:on_receive_request_data(Bin, CallbackState),
    NewStream = Stream#stream_state{
                  incoming_frames=queue:in(F, IFQ),
                  request_body_size=Stream#stream_state.request_body_size+L,
                  request_end_stream=true,
                  callback_state=CallbackState1
                 },
    case check_content_length(NewStream) of
        ok ->
            {ok, NewCBState} = CB:on_request_end_stream(CallbackState1),
            {next_state,
             half_closed_remote,
             NewStream#stream_state{
               callback_state=NewCBState
              }};
        rst_stream ->
            {next_state,
             closed,
             NewStream}
        end;

%% Trailers
open({recv_h, Trailers},
     #stream_state{}=Stream) ->
    case is_valid_headers(request, Trailers) of
        ok ->
            {next_state,
             open,
             Stream#stream_state{
               request_headers=Stream#stream_state.request_headers ++ Trailers
              }};
        {error, Code} ->
            rst_stream_(Code, Stream)
    end;
open({send_frame,
      {#frame_header{
          type=?DATA,
          flags=Flags
         }, _}=F},
     #stream_state{
        socket=Socket
       }=Stream) ->
    sock:send(Socket, http2_frame:to_binary(F)),

    NextState =
        case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
            true ->
                half_closed_local;
            _ ->
                open
        end,
    {next_state, NextState, Stream};
open(Msg, Stream) ->
    lager:warning("Some unexpected message in open state. ~p, ~p", [Msg, Stream]),
    {next_state, open, Stream}.

half_closed_remote(
  {send_h, Headers},
  #stream_state{}=Stream) ->
    {next_state,
     half_closed_remote,
     Stream#stream_state{
       response_headers=Headers
      }};
half_closed_remote(
                  {send_frame,
                   {
                     #frame_header{
                        flags=Flags,
                        type=?DATA
                       },_
                   }=F}=_Msg,
  #stream_state{
     socket=Socket
    }=Stream) ->
    ok = sock:send(Socket, http2_frame:to_binary(F)),

    case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
        true ->
            {next_state, closed, Stream, 0};
        _ ->
            {next_state, half_closed_remote, Stream}
    end;
half_closed_remote(_,
       #stream_state{}=Stream) ->
    rst_stream_(?STREAM_CLOSED, Stream).

%% PUSH_PROMISES can only be received by streams in the open or
%% half_closed_local, but will create a new stream in the idle state,
%% but that stream may be ready to transition, it'll make sense, I
%% hope!
half_closed_local(
  {recv_h, Headers},
  #stream_state{
    }=Stream) ->
  case is_valid_headers(response, Headers) of
      ok ->
          {next_state,
           half_closed_local,
           Stream#stream_state{
             response_headers=Headers}};
      {error, Code} ->
          rst_stream_(Code, Stream)
  end;
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
            Data =
                [ http2_frame_data:data(Payload)
                  || {#frame_header{type=?DATA}, Payload} <- queue:to_list(NewQ)],
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
              }, 0};
        _ ->
            {next_state,
             half_closed_local,
             Stream#stream_state{
               incoming_frames=NewQ
              }}
    end;
half_closed_local(_,
       #stream_state{}=Stream) ->
    rst_stream_(?STREAM_CLOSED, Stream).

closed(timeout,
       #stream_state{}=Stream) ->
    gen_fsm:send_all_state_event(Stream#stream_state.connection,
                                 {stream_finished,
                                  Stream#stream_state.stream_id,
                                  Stream#stream_state.response_headers,
                                  Stream#stream_state.response_body}),
    {stop, normal, Stream};
closed(_,
       #stream_state{}=Stream) ->
    rst_stream_(?STREAM_CLOSED, Stream).

handle_event({send_window_update, 0},
             StateName,
             #stream_state{}=Stream) ->
    {next_state, StateName, Stream};
handle_event({send_window_update, Size},
             StateName,
             #stream_state{
                socket=Socket,
                stream_id=StreamId
               }=Stream) ->
    http2_frame_window_update:send(Socket, Size, StreamId),
    {next_state, StateName,
     Stream#stream_state{
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

-spec rst_stream_(error_code(), state()) ->
                         {next_state,
                          closed,
                          state()}.
rst_stream_(ErrorCode,
           #stream_state{
              socket=Socket,
              stream_id=StreamId
              }=Stream
          ) ->
    RstStream = http2_frame_rst_stream:new(ErrorCode),
    RstStreamBin = http2_frame:to_binary(
                     {#frame_header{
                         stream_id=StreamId
                        },
                      RstStream}),
    sock:send(Socket, RstStreamBin),
    {next_state,
     closed,
     Stream}.

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
