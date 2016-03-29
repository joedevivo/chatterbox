-module(http2_connection).

-behaviour(gen_fsm).

-include("http2.hrl").

-export([
         start_client_link/5,
         start_ssl_upgrade_link/5,
         start_server_link/3,
         become/1,
         become/2,
         stop/1
        ]).

-export([
         send_headers/3,
         send_body/3,
         is_push/1,
         new_stream/1,
         new_stream/2,
         send_promise/4,
         get_response/2,
         get_peer/1,
         get_streams/1,
         send_window_update/2,
         send_frame/2
        ]).

%% gen_fsm callbacks
-export([
    init/1,
    handle_event/3,
    handle_sync_event/4,
    handle_info/3,
    code_change/4,
    terminate/3
]).

-export([
         listen/2,
         handshake/2,
         connected/2,
         continuation/2,
         closing/2
        ]).

-export([
         go_away/2
        ]).

-record(h2_listening_state, {
          ssl_options   :: [ssl:ssloption()],
          listen_socket :: ssl:sslsocket() | inet:socket(),
          transport     :: gen_tcp | ssl,
          listen_ref    :: non_neg_integer(),
          acceptor_callback = fun chatterbox_sup:start_socket/0 :: fun(),
          server_settings = #settings{} :: settings()
         }).

-record(continuation_state, {
          stream_id                 :: stream_id(),
          promised_id = undefined   :: undefined | stream_id(),
          frames      = queue:new() :: queue:queue(frame()),
          type                      :: headers | push_promise,
          end_stream  = false       :: boolean(),
          end_headers = false       :: boolean()
}).


-record(stream, {
          id :: stream_id(),
          pid :: pid(),
          send_window_size :: non_neg_integer(),
          recv_window_size :: non_neg_integer(),
          queued_data :: undefined | done | binary()
         }).
-type stream() :: #stream{}.

-record(connection, {
          type = undefined :: client | server | undefined,
          ssl_options = [],
          listen_ref :: non_neg_integer(),
          socket = undefined :: sock:socket(),
          send_settings = #settings{} :: settings(),
          recv_settings = #settings{} :: settings(),
          send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          decode_context = hpack:new_context() :: hpack:context(),
          encode_context = hpack:new_context() :: hpack:context(),
          settings_sent = queue:new() :: queue:queue(),
          next_available_stream_id = 2 :: stream_id(),
          streams = [] :: [stream()],
          stream_callback_mod = application:get_env(chatterbox, stream_callback_mod, chatterbox_static_stream) :: module(),
          content_handler = application:get_env(chatterbox, content_handler, chatterbox_static_content_handler) :: module(),
          buffer = empty :: empty | {binary, binary()} | {frame, frame_header(), binary()},
          continuation = undefined :: undefined | #continuation_state{},
          flow_control = auto :: auto | manual
}).

-type connection() :: #connection{}.

-spec start_client_link(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:ssloption()],
                        settings()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link(Transport, Host, Port, SSLOptions, Http2Settings) ->
    gen_fsm:start_link(?MODULE, {client, Transport, Host, Port, SSLOptions, Http2Settings}, []).

-spec start_ssl_upgrade_link(inet:ip_address() | inet:hostname(),
                             inet:port_number(),
                             binary(),
                             [ssl:ssloption()],
                             settings()
                            ) ->
                                    {ok, pid()} | ignore | {error, term()}.
start_ssl_upgrade_link(Host, Port, InitialMessage, SSLOptions, Http2Settings) ->
    gen_fsm:start_link(?MODULE, {client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions, Http2Settings}, []).

-spec start_server_link(socket(),
                        [ssl:ssloption()],
                        #settings{}) ->
                               {ok, pid()} | ignore | {error, term()}.
start_server_link({Transport, ListenSocket}, SSLOptions, Http2Settings) ->
    gen_fsm:start_link(?MODULE, {server, {Transport, ListenSocket}, SSLOptions, Http2Settings}, []).

-spec become(socket()) -> no_return().
become(Socket) ->
    become(Socket, chatterbox:settings(server)).

-spec become(socket(), settings()) -> no_return().
become({Transport, Socket}, Http2Settings) ->
    ok = Transport:setopts(Socket, [{packet, raw}, binary]),
    {_, _, NewState} =
        start_http2_server(Http2Settings,
                           #connection{
                              socket = {Transport, Socket}
                             }),
    gen_fsm:enter_loop(?MODULE,
                       [],
                       handshake,
                       NewState).

%% Init callback
init({client, Transport, Host, Port, SSLOptions, Http2Settings}) ->
    {ok, Socket} = Transport:connect(Host, Port, client_options(Transport, SSLOptions)),
    ok = Transport:setopts(Socket, [{packet, raw}, binary]),
    Transport:send(Socket, <<?PREFACE>>),
    InitialState =
        #connection{
           type = client,
           socket = {Transport, Socket},
           next_available_stream_id=1,
           flow_control=application:get_env(chatterbox, client_flow_control, auto)
          },
    {ok,
     handshake,
     send_settings(Http2Settings, InitialState),
     4500};
init({client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions, Http2Settings}) ->
    {ok, TCP} = gen_tcp:connect(Host, Port, [{active, false}]),
    gen_tcp:send(TCP, InitialMessage),
    {ok, Socket} = ssl:connect(TCP, client_options(ssl, SSLOptions)),

    active_once({ssl, Socket}),
    ok = ssl:setopts(Socket, [{packet, raw}, binary]),
    ssl:send(Socket, <<?PREFACE>>),
    InitialState =
        #connection{
           type = client,
           socket = {ssl, Socket},
           next_available_stream_id=1,
           flow_control=application:get_env(chatterbox, client_flow_control, auto)
          },
    {ok,
     handshake,
     send_settings(Http2Settings, InitialState),
     4500};
init({server, {Transport, ListenSocket}, SSLOptions, Http2Settings}) ->
    %% prim_inet:async_accept is dope. It says just hang out here and
    %% wait for a message that a client has connected. That message
    %% looks like:
    %% {inet_async, ListenSocket, Ref, {ok, ClientSocket}}
    {ok, Ref} = prim_inet:async_accept(ListenSocket, -1),
    {ok,
     listen,
     #h2_listening_state{
        ssl_options = SSLOptions,
        listen_socket = ListenSocket,
        listen_ref = Ref,
        transport = Transport,
        server_settings = Http2Settings
       }}. %% No timeout here, it's just a listener

send_frame(Pid, Bin)
  when is_binary(Bin); is_list(Bin) ->
    gen_fsm:send_all_state_event(Pid, {send_bin, Bin});
send_frame(Pid, Frame) ->
    gen_fsm:send_all_state_event(Pid, {send_frame, Frame}).

-spec send_headers(pid(), stream_id(), hpack:headers()) -> ok.
send_headers(Pid, StreamId, Headers) ->
    gen_fsm:send_all_state_event(Pid, {send_headers, StreamId, Headers}),
    ok.

-spec send_body(pid(), stream_id(), binary()) -> ok.
send_body(Pid, StreamId, Body) ->
    gen_fsm:send_all_state_event(Pid, {send_body, StreamId, Body}),
    ok.

-spec get_peer(pid()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
get_peer(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, get_peer).

-spec is_push(pid()) -> boolean().
is_push(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, is_push).

-spec new_stream(pid()) -> stream_id().
new_stream(Pid) ->
    new_stream(Pid, self()).

-spec new_stream(pid(), pid()) -> stream_id().
new_stream(Pid, NotifyPid) ->
    gen_fsm:sync_send_all_state_event(Pid, {new_stream, NotifyPid}).

-spec send_promise(pid(), stream_id(), stream_id(), hpack:headers()) -> ok.
send_promise(Pid, StreamId, NewStreamId, Headers) ->
    gen_fsm:send_all_state_event(Pid, {send_promise, StreamId, NewStreamId, Headers}),
    ok.

-spec get_response(pid(), stream_id()) ->
                          {ok, {hpack:headers(), iodata()}}
                              | {error, term()}.
get_response(Pid, StreamId) ->
    gen_fsm:sync_send_all_state_event(Pid, {get_response, StreamId}).

-spec get_streams(pid()) -> [{stream_id(), pid()}].
get_streams(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, streams).

-spec send_window_update(pid(), non_neg_integer()) -> ok.
send_window_update(Pid, Size) ->
    gen_fsm:send_all_state_event(Pid, {send_window_update, Size}).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).

%% The listen state only exists to wait around for new prim_inet
%% connections
listen(timeout, State) ->
    go_away(?PROTOCOL_ERROR, State).

-spec handshake(timeout|{frame, frame()}, connection()) ->
                    {next_state,
                     handshake|connected|closing,
                     connection()}.
handshake(timeout, State) ->
    go_away(?PROTOCOL_ERROR, State);
handshake({frame, {FH, _Payload}=Frame}, State) ->
    %% The first frame should be the client settings as per
    %% RFC-7540#3.5
    case FH#frame_header.type of
        ?SETTINGS ->
            route_frame(Frame, State);
        _ ->
            go_away(?PROTOCOL_ERROR, State)
    end.

connected({frame, Frame},
          #connection{}=Conn
         ) ->
    lager:debug("[~p][connected] {frame, ~p}",
                [Conn#connection.type, http2_frame:format(Frame)]),
    route_frame(Frame, Conn).

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state
continuation({frame,
              {#frame_header{
                  stream_id=StreamId,
                  type=?CONTINUATION
                 }, _}=Frame},
             #connection{
                continuation = #continuation_state{
                                  stream_id = StreamId
                                 }
               }=Conn) ->
    lager:debug("[~p][continuation] [next] ~p",
                [Conn#connection.type, http2_frame:format(Frame)]),
    route_frame(Frame, Conn);
continuation(_, Conn) ->
    go_away(?PROTOCOL_ERROR, Conn).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.
closing(Message,
        #connection{
           socket=Socket
          }=Conn) ->
    lager:debug("[~p][closing] s ~p",
                [Conn#connection.type, Message]),
    sock:close(Socket),
    {stop, normal, Conn};
closing(Message, Conn) ->
    lager:debug("[~p][closing] ~p",
                [Conn#connection.type, Message]),
    {stop, normal, Conn}.

%% route_frame's job needs to be "now that we've read a frame off the
%% wire, do connection based things to it and/or forward it to the
%% http2 stream processor (http2_stream:recv_frame)
-spec route_frame(frame() | {error, term()}, connection()) ->
    {next_state,
     connected | continuation | closing ,
     connection()}.
%% Bad Length of frame, exceedes maximum allowed size
route_frame({#frame_header{length=L}, _},
            #connection{
               recv_settings=#settings{max_frame_size=MFS}
              }=Conn)
    when L > MFS ->
    go_away(?FRAME_SIZE_ERROR, Conn);
%% Some types have fixed lengths and there's nothing we can do about
%% it except Frame Size error
route_frame({#frame_header{
                length=L,
                type=T}, _Payload},
            #connection{}=Conn)
  when (T == ?PRIORITY      andalso L =/= 5) orelse
       (T == ?RST_STREAM    andalso L =/= 4) orelse
       (T == ?PING          andalso L =/= 8) orelse
       (T == ?WINDOW_UPDATE andalso L =/= 4) ->
    go_away(?FRAME_SIZE_ERROR, Conn);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Protocol Errors
%%

%% Not allowed on Stream 0:
%% - DATA
%% - HEADERS
%% - PRIORITY
%% - RST_STREAM
%% - PUSH_PROMISE
%% - CONTINUATION
route_frame({#frame_header{
                stream_id=0,
                type=Type
                },_Payload},
            #connection{} = Conn)
  when Type == ?DATA;
       Type == ?HEADERS;
       Type == ?PRIORITY;
       Type == ?RST_STREAM;
       Type == ?PUSH_PROMISE;
       Type == ?CONTINUATION ->
    lager:error("[~p] ~p frame not allowed on stream 0",
                [Conn#connection.type, ?FT(Type)]),
    go_away(?PROTOCOL_ERROR, Conn);

%% Only allowed on stream 0
route_frame({#frame_header{
                stream_id=StreamId,
                type=Type
                },_Payload},
            #connection{} = Conn)
  when StreamId > 0 andalso (
       Type == ?SETTINGS orelse
       Type == ?PING orelse
       Type == ?GOAWAY) ->
    lager:error("[~p] ~p frame only allowed on stream 0",
                [Conn#connection.type, ?FT(Type)]),
    go_away(?PROTOCOL_ERROR, Conn);

route_frame({#frame_header{
                type=?WINDOW_UPDATE,
                stream_id=StreamId
               },
             #window_update{
                window_size_increment=WSI
                }},
            #connection{} = Conn)
  when WSI < 1 ->
    case StreamId of
        0 ->
            go_away(?PROTOCOL_ERROR, Conn);
        _ ->
            Stream = get_stream(StreamId, Conn#connection.streams),
            http2_stream:rst_stream(Stream#stream.pid, ?PROTOCOL_ERROR)
    end;


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Connection Level Frames
%%
%% Here we'll handle anything that belongs on stream 0.

%% SETTINGS, finally something that's ok on stream 0
%% This is the non-ACK case, where settings have actually arrived
route_frame({H, Payload},
            #connection{
               send_settings=SS=#settings{
                                   initial_window_size=OldIWS,
                                   header_table_size=HTS
                                  },
               streams=Streams,
               encode_context=EncodeContext
              }=Conn)
    when H#frame_header.type == ?SETTINGS,
         ?NOT_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("[~p] Received SETTINGS",
               [Conn#connection.type]),
    %% Need a way of processing settings so I know which ones came in
    %% on this one payload.
    case http2_frame_settings:validate(Payload) of
        ok ->
            {settings, PList} = Payload,

            Delta =
                case proplists:get_value(?SETTINGS_INITIAL_WINDOW_SIZE, PList) of
                    undefined ->
                        0;
                    NewIWS ->
                        OldIWS - NewIWS
                end,
            NewSendSettings = http2_frame_settings:overlay(SS, Payload),
            %% We've just got connection settings from a peer. He have a
            %% couple of jobs to do here w.r.t. flow control

            %% If Delta != 0, we need to change every stream's
            %% send_window_size in the state open or
            %% half_closed_remote. We'll just send the message
            %% everywhere. It's up to them if they need to do
            %% anything.
            UpdatedStreams =
                [ S#stream{
                    send_window_size=S#stream.send_window_size+Delta
                   } || S <- Streams],

            NewEncodeContext = hpack:new_max_table_size(HTS, EncodeContext),

            socksend(Conn, http2_frame_settings:ack()),
            lager:debug("[~p] Sent Settings ACK",
                        [Conn#connection.type]),
            {next_state, connected, Conn#connection{
                                      send_settings=NewSendSettings,
                                      %% Why aren't we updating send_window_size here? Section 6.9.2 of
                                      %% the spec says: "The connection flow-control window can only be
                                      %% changed using WINDOW_UPDATE frames.",
                                      encode_context=NewEncodeContext,
                                      streams=UpdatedStreams
                                     }};
        {error, Code} ->
            go_away(Code, Conn)

    end;

%% This is the case where we got an ACK, so dequeue settings we're
%% waiting to apply
route_frame({H, _Payload},
            #connection{
               settings_sent=SS,
               streams=Streams,
               recv_settings=#settings{
                                initial_window_size=OldIWS
                               }
              }=Conn)
    when H#frame_header.type == ?SETTINGS,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("[~p] Received SETTINGS ACK",
               [Conn#connection.type]),
    case queue:out(SS) of
        {{value, {_Ref, NewSettings}}, NewSS} ->

            UpdatedStreams =
                case NewSettings#settings.initial_window_size of
                    undefined ->
                        ok;
                    NewIWS ->
                        Delta = OldIWS - NewIWS,
                        [ S#stream{
                            send_window_size=S#stream.send_window_size+Delta
                           } || S <- Streams]
                end,

            {next_state,
             connected,
             Conn#connection{
               streams=UpdatedStreams,
               settings_sent=NewSS,
               recv_settings=NewSettings
               %% Same thing here, section 6.9.2
              }};
        _X ->
            {next_state, closing, Conn}
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stream level frames
%%

%% receive data frame bigger than connection recv window
route_frame({H,_Payload}, Conn)
    when H#frame_header.type == ?DATA,
         H#frame_header.length > Conn#connection.recv_window_size ->
    lager:debug("[~p] Received DATA Frame for Stream ~p with L > CRWS",
                [Conn#connection.type, H#frame_header.stream_id]),
    go_away(?FLOW_CONTROL_ERROR, Conn);

route_frame(F={H=#frame_header{
                    length=L,
                    stream_id=StreamId}, _Payload},
            #connection{
               recv_window_size=CRWS,
               streams=Streams
              }=Conn)
    when H#frame_header.type == ?DATA ->
    lager:debug("[~p] Received DATA Frame for Stream ~p",
                [Conn#connection.type, StreamId]),
    Stream = get_stream(StreamId, Streams),

    case {
      Stream#stream.recv_window_size =< L,
      Conn#connection.flow_control,
      L > 0
         } of
        {true, _, _} ->
            lager:error("[~p][Stream ~p] Flow Control got ~p bytes, Stream window was ~p",
                        [Conn#connection.type, StreamId, L, Stream#stream.recv_window_size]),
            http2_stream:rst_stream(Stream#stream.pid,
                                    ?FLOW_CONTROL_ERROR);
        {false, auto, true} ->
            %% Make window size great again
            lager:info("[~p] Stream ~p WindowUpdate ~p",
                       [Conn#connection.type, StreamId, L]),
            http2_frame_window_update:send(Conn#connection.socket,
                                           L, StreamId),
            send_window_update(self(), L);
        _Tried ->
            ok
    end,

    http2_stream:recv_frame(Stream#stream.pid, F),

    {next_state,
     connected,
     Conn#connection{
       recv_window_size=CRWS-L,
       streams=replace_stream(
                 Stream#stream{
                   recv_window_size=Stream#stream.recv_window_size-L
                  }, Streams)
      }};

route_frame({#frame_header{type=?HEADERS}=FH, _Payload},
            #connection{}=Conn)
  when Conn#connection.type == server,
       FH#frame_header.stream_id rem 2 == 0 ->
    go_away(?PROTOCOL_ERROR, Conn);
route_frame({#frame_header{stream_id=StreamId, type=?HEADERS}=FH, #headers{priority=P}},
            #connection{}=Conn)
  when ?IS_FLAG(FH#frame_header.flags, ?FLAG_PRIORITY),
       P#priority.stream_id == FH#frame_header.stream_id ->
    rst_stream(StreamId, ?PROTOCOL_ERROR, Conn);
route_frame({#frame_header{type=?HEADERS}=FH, _Payload}=Frame,
            #connection{}=Conn) ->
    StreamId = FH#frame_header.stream_id,
    Streams = Conn#connection.streams,

    lager:debug("[~p] Received HEADERS Frame for Stream ~p",
                [Conn#connection.type, StreamId]),

    %% Four things could be happening here.

    %% 1. We're a server, and these are Request Headers.

    %% 2. We're a client, and these are Response Headers.

    %% 3. We're a client, and these are Response Headers, but the
    %% response is to a Push Promise

    %% 4. We're a server and these are Request Trailers :/

    %% Fortunately, the only thing we need to do here is create a new
    %% stream if this is the first scenario. The stream will already
    %% exist if this is a PP or Response

    NewConn =
        case get_stream(StreamId, Streams) of
            false ->
                NewStream = new_stream_(StreamId, Conn),
                Conn#connection{streams=[NewStream|Streams]};
            _Stream ->
                Conn
        end,

    %% If there's an END_HEADERS flag, the headers were only one
    %% frame.

    %% If not, we have to wait for all the CONTINUATIONS to roll in.

    %% If there's an END_STREAM flag set AND END_HEADERS, we're done
    %% with the request.

    %% If there's and END_STREAM and no END_HEADERS, we'll be done
    %% once those CONTINUATIONS arrive

    %% So what do we do? We construct a #continuation record that
    %% covers a whole bunch of things and is run through a function
    %% when every HEADERS, PUSH_PROMISE, or CONTINUATION rolls
    %% in. Let's give it a whirl.

    ContinuationState =
        #continuation_state{
           type = headers,
           frames = queue:from_list([Frame]),
           end_stream = ?IS_FLAG(FH#frame_header.flags, ?FLAG_END_STREAM),
           end_headers = ?IS_FLAG(FH#frame_header.flags, ?FLAG_END_HEADERS),
           stream_id = StreamId
          },

    maybe_hpack(ContinuationState, NewConn);
route_frame(F={H=#frame_header{
                    stream_id=StreamId,
                    type=?CONTINUATION
                   }, _Payload},
            #connection{
               continuation = #continuation_state{
                                 frames = CFQ,
                                 stream_id = StreamId
                                } = Cont
              }=Conn) ->
    lager:debug("[~p] Received CONTINUATION Frame for Stream ~p",
                [Conn#connection.type, StreamId]),

    maybe_hpack(Cont#continuation_state{
                  frames=queue:in(F, CFQ),
                  end_headers=?IS_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS)
                 },
                Conn);

route_frame({H, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?PRIORITY,
         H#frame_header.stream_id == 0 ->
    go_away(?PROTOCOL_ERROR, Conn);
route_frame({#frame_header{type=?PRIORITY, stream_id=StreamId}, #priority{}=P},
            #connection{}=Conn)
  when StreamId == P#priority.stream_id ->
    rst_stream(StreamId, ?PROTOCOL_ERROR, Conn);
route_frame({H, _Payload},
            #connection{} = Conn)
    when H#frame_header.type == ?PRIORITY ->
    lager:debug("[~p] Received PRIORITY Frame, but it's only a suggestion anyway...",
               [Conn#connection.type]),
    {next_state, connected, Conn};

route_frame(
  {#frame_header{
      stream_id=StreamId,
      type=?RST_STREAM
      },
   #rst_stream{
      error_code=EC
      }},
  #connection{} = Conn) ->
    lager:debug("[~p] Received RST_STREAM (~p) for Stream ~p",
                [Conn#connection.type, EC, StreamId]),
    Streams = Conn#connection.streams,
    case get_stream(StreamId, Streams) of
        false ->
            go_away(?PROTOCOL_ERROR, Conn);
        _Stream ->
            %% TODO: RST_STREAM support
            {next_state, connected, Conn}
    end;
route_frame({H=#frame_header{
                  stream_id=StreamId
                 },
             #push_promise{
                promised_stream_id=PSID
                }}=Frame,
            #connection{}=Conn)
    when H#frame_header.type == ?PUSH_PROMISE ->

    lager:debug("[~p] Received PUSH_PROMISE Frame on Stream ~p for Stream ~p",
                [Conn#connection.type, StreamId, PSID]),

    Streams = Conn#connection.streams,
    Old = get_stream(StreamId, Streams),
    {ok, NotifyPid} = http2_stream:notify_pid(Old#stream.pid),

    New = new_stream_(PSID, NotifyPid, Conn),

    lager:debug("[~p] recv(~p, {~p, ~p})",
                [Conn#connection.type, Frame, StreamId, Conn]),

    Continuation = #continuation_state{
                      stream_id=StreamId,
                      type=push_promise,
                      frames = queue:in(Frame, queue:new()),
                      end_headers=?IS_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS),
                      promised_id=PSID
                     },

    maybe_hpack(Continuation,
                Conn#connection{
                  streams = [New|Streams]
                 });

%% PING

%% If not stream 0, then connection error
route_frame({H, _Payload},
            #connection{} = Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.stream_id =/= 0 ->
    go_away(?PROTOCOL_ERROR, Conn);
%% If length != 8, FRAME_SIZE_ERROR
route_frame({H, _Payload},
           #connection{}=Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.length =/= 8 ->
    go_away(?FRAME_SIZE_ERROR, Conn);
%% If PING && !ACK, must ACK
route_frame({H, Ping},
            #connection{}=Conn)
    when H#frame_header.type == ?PING,
         ?NOT_FLAG(#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("[~p] Received PING",
               [Conn#connection.type]),
    Ack = http2_frame_ping:ack(Ping),
    socksend(Conn, http2_frame:to_binary(Ack)),
    {next_state, connected, Conn};
route_frame({H, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?PING,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("[~p] Received PING ACK",
               [Conn#connection.type]),
    {next_state, connected, Conn};
route_frame({H=#frame_header{stream_id=0}, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?GOAWAY ->
    lager:debug("[~p] Received GOAWAY Frame for Stream 0",
               [Conn#connection.type]),
    go_away(?NO_ERROR, Conn);
route_frame(
  {#frame_header{
      stream_id=0,
      type=?WINDOW_UPDATE
     },
   #window_update{window_size_increment=WSI}},
  #connection{
     send_window_size=SWS
    }=Conn) ->

    lager:debug("[~p] Stream 0 Window Update: ~p",
                [Conn#connection.type, WSI]),
    NewSendWindow = SWS+WSI,
    case NewSendWindow > 2147483647 of
        true ->
            go_away(?FLOW_CONTROL_ERROR, Conn);
        false ->
            %% TODO: Priority Sort! Right now, it's just sorting on
            %% lowest stream_id first
            Streams = sort_streams(Conn#connection.streams),

            {RemainingSendWindow, UpdatedStreams} =
                c_send_what_we_can(
                  NewSendWindow,
                  Conn#connection.send_settings#settings.max_frame_size,
                  Streams
                 ),
            lager:debug("[~p] and Connection Send Window now: ~p",
                        [Conn#connection.type, RemainingSendWindow]),
            {next_state, connected,
             Conn#connection{
               send_window_size=RemainingSendWindow,
               streams=UpdatedStreams
              }}
    end;
route_frame(
  {#frame_header{type=?WINDOW_UPDATE}=FH,
   #window_update{window_size_increment=WSI}},
  #connection{}=Conn
 ) ->
    StreamId = FH#frame_header.stream_id,
    Streams = Conn#connection.streams,

    lager:debug("[~p] Received WINDOW_UPDATE Frame for Stream ~p",
                [Conn#connection.type, StreamId]),

    case get_stream(StreamId, Streams) of
        false ->
            lager:error("[~p] Window update for an idle stream (~p)",
                       [Conn#connection.type, StreamId]),
            go_away(?PROTOCOL_ERROR, Conn);
        S ->
            SWS = Conn#connection.send_window_size,
            NewSSWS = S#stream.send_window_size+WSI,

            case NewSSWS > 2147483647 of
                true ->
                    lager:error("Sending ~p FLOWCONTROL ERROR because NSW = ~p", [StreamId, NewSSWS]),
                    http2_stream:rst_stream(S#stream.pid, ?FLOW_CONTROL_ERROR),
                    {next_state, connected,
                     Conn#connection{
                       %streams = delete_stream(S, Streams)
                      }};
                false ->
                    lager:debug("Stream ~p send window now: ~p", [StreamId, NewSSWS]),
                    {RemainingSendWindow, NewS}
                        = s_send_what_we_can(
                            SWS,
                            Conn#connection.send_settings#settings.max_frame_size,
                            S#stream{send_window_size=NewSSWS}
                           ),
                    {next_state, connected,
                     Conn#connection{
                       send_window_size=RemainingSendWindow,
                       streams=replace_stream(NewS, Streams)
                      }}
            end
    end;
route_frame({#frame_header{type=T}, _}, Conn)
  when T > ?CONTINUATION ->
    lager:debug("Ignoring Unsupported Expansion Frame"),
    {next_state, connected, Conn};
route_frame(Frame, #connection{}=Conn) ->
    lager:error("[~p] Frame condition not covered by pattern match",
               [Conn#connection.type]),
    lager:error("This is bad and you probably found a bug. Please open a github issue with this output:"),
    lager:error("OOPS! " ++ http2_frame:format(Frame)),
    lager:error("OOPS! ~p", [Conn]),
    go_away(?PROTOCOL_ERROR, Conn).

%% Send at the connection level
-spec c_send_what_we_can(non_neg_integer(),
                         non_neg_integer(),
                         [stream()]) ->
                                {non_neg_integer(), [stream()]}.
c_send_what_we_can(SWS, MaxFrameSize, Streams) ->
    c_send_what_we_can(SWS, MaxFrameSize, Streams, []).
%% If we hit 0, done
c_send_what_we_can(0, _MFS, Streams, Acc) ->
    {0, lists:reverse(Acc) ++ Streams};
%% If we hit end of streams list, done
c_send_what_we_can(SWS, _MFS, [], Acc) ->
    {SWS, lists:reverse(Acc)};
%% Otherwise, try sending on the working stream
c_send_what_we_can(SWS, MFS, [S|Streams], Acc) ->
    {NewSWS, NewS} = s_send_what_we_can(SWS, MFS, S),
    c_send_what_we_can(NewSWS, MFS, Streams, [NewS|Acc]).

%% Send at the stream level
s_send_what_we_can(SWS, _, #stream{queued_data=Data}=S)
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

    SSWS = Stream#stream.send_window_size,

    QueueSize = byte_size(Stream#stream.queued_data),

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
                %% We have the power to send everything
                {{#frame_header{
                     stream_id=Stream#stream.id,
                     flags=?FLAG_END_STREAM,
                     type=?DATA,
                     length=QueueSize
                    },
                  #data{
                     data=Stream#stream.queued_data %% Full Body
                    }},
                 QueueSize,
                 Stream#stream{
                   queued_data=done,
                   send_window_size=SSWS-QueueSize}};
            false ->
                <<BinToSend:MaxToSend/binary,Rest/binary>> = Stream#stream.queued_data,
                {{#frame_header{
                     stream_id=Stream#stream.id,
                     type=?DATA,
                     length=MaxToSend
                    },
                  #data{
                     data=BinToSend
                    }},
                 MaxToSend,
                 Stream#stream{
                   queued_data=Rest,
                   send_window_size=SSWS-MaxToSend}}
        end,

    _Sent = http2_stream:send_frame(Stream#stream.pid, Frame),

    case ExitStrategy of
        max_frame_size ->
            s_send_what_we_can(SWS - SentBytes, MFS, NewS);
        stream ->
            {SWS - SentBytes, NewS};
        connection ->
            {0, NewS}
    end.

handle_event({send_window_update, 0},
             StateName, Conn) ->
    {next_state, StateName, Conn};
handle_event({send_window_update, Size},
             StateName,
             #connection{
                recv_window_size=CRWS,
                socket=Socket
                }=Conn) ->
    ok = http2_frame_window_update:send(Socket, Size, 0),
    {next_state,
     StateName,
     Conn#connection{
       recv_window_size=CRWS+Size
      }};
handle_event({send_headers, StreamId, Headers},
             StateName,
             #connection{
                encode_context=EncodeContext,
                streams = Streams,
                socket = Socket
               }=Conn
            ) ->
    lager:debug("[~p] {send headers, ~p, ~p}",
                [Conn#connection.type, StreamId, Headers]),
    Stream = get_stream(StreamId, Streams),

    %% TODO: This is set up in a way that assumes the header frame is
    %% smaller than MAX_FRAME_SIZE. Will need to split that out into
    %% continuation frames,but now will definitely be a
    %% FRAME_SIZE_ERROR
    {HeaderFrame, NewContext} = http2_frame_headers:to_frame(Stream#stream.id, Headers, EncodeContext),
    sock:send(Socket, http2_frame:to_binary(HeaderFrame)),
    http2_stream:send_h(Stream#stream.pid, Headers),

    {next_state, StateName,
     Conn#connection{
       encode_context=NewContext
      }};
handle_event({send_body, StreamId, Body},
             StateName,
             #connection{}=Conn) ->
    lager:debug("[~p] Send Body Stream ~p",
                [Conn#connection.type, StreamId]),
    Stream = get_stream(StreamId, Conn#connection.streams),
    {NewSWS, NewS} =
        s_send_what_we_can(Conn#connection.send_window_size,
                           Conn#connection.send_settings#settings.max_frame_size,
                           Stream#stream{
                            queued_data=Body
                            }),

    {next_state, StateName,
     Conn#connection{
       send_window_size=NewSWS,
       streams=replace_stream(NewS, Conn#connection.streams)
      }};

handle_event({send_promise, StreamId, NewStreamId, Headers},
             StateName,
             #connection{
                streams=Streams,
                encode_context=OldContext
               }=Conn
            ) ->
    NewStream = get_stream(NewStreamId, Streams),

    %% TODO: This could be a series of frames, not just one
    {PromiseFrame, NewContext} = http2_frame_push_promise:to_frame(
                                   StreamId,
                                   NewStreamId,
                                   Headers,
                                   OldContext
                                  ),

    %% Send the PP Frame
    Binary = http2_frame:to_binary(PromiseFrame),
    socksend(Conn, Binary),

    %% Get the promised stream rolling
    http2_stream:send_pp(NewStream#stream.pid, Headers),

    {next_state, StateName,
     Conn#connection{
       encode_context=NewContext
      }};

handle_event({check_settings_ack, {Ref, NewSettings}},
             StateName,
             #connection{
                settings_sent=SS
               }=Conn) ->
    case queue:out(SS) of
        {{value, {Ref, NewSettings}}, _} ->
            %% This is still here!
            go_away(?SETTINGS_TIMEOUT, Conn);
        _ ->
            %% YAY!
            {next_state, StateName, Conn}
    end;
handle_event({send_bin, Binary}, StateName,
             #connection{} = Conn) ->
    socksend(Conn, Binary),
    {next_state, StateName, Conn};
handle_event({send_frame, Frame}, StateName,
             #connection{} =Conn) ->
    Binary = http2_frame:to_binary(Frame),
    socksend(Conn, Binary),
    {next_state, StateName, Conn};
handle_event(stop, _StateName,
            #connection{}=Conn) ->
    go_away(0, Conn);
handle_event(_E, StateName, Conn) ->
    {next_state, StateName, Conn}.

handle_sync_event(streams, _F, StateName,
                  #connection{
                     streams=Streams
                    }=Conn) ->
    {reply, Streams, StateName, Conn};
handle_sync_event({get_response, StreamId}, _F, StateName,
                  #connection{}=Conn) ->
    Stream = get_stream(StreamId, Conn#connection.streams),
    Reply = http2_stream:get_response(Stream#stream.pid),

    {reply, Reply, StateName, Conn};
handle_sync_event({new_stream, NotifyPid}, _F, StateName,
                  #connection{
                     streams=Streams,
                     next_available_stream_id=NextId
                    }=Conn) ->

    NewStream = new_stream_(NextId, NotifyPid, Conn),
    lager:debug("[~p] added stream #~p to ~p",
                [Conn#connection.type, NextId, Streams]),
    {reply, NextId, StateName, Conn#connection{
                                 next_available_stream_id=NextId+2,
                                 streams=[NewStream|Streams]
                                }};
handle_sync_event(is_push, _F, StateName,
                  #connection{
                     send_settings=#settings{enable_push=Push}
                    }=Conn) ->
    IsPush = case Push of
        1 -> true;
        _ -> false
    end,
    {reply, IsPush, StateName, Conn};
handle_sync_event(get_peer, _F, StateName,
                  #connection{
                     socket={Transport,_}=Socket
                    }=Conn) ->
    case sock:peername(Socket) of
        {error, _}=Error ->
            lager:warning("failed to fetch peer for ~p socket",
                          [Transport]),
            {reply, Error, StateName, Conn};
        {ok, _AddrPort}=OK ->
            {reply, OK, StateName, Conn}
    end;
handle_sync_event(_E, _F, StateName,
                  #connection{}=Conn) ->
    {next_state, StateName, Conn}.

handle_info({inet_async, ListenSocket, Ref, {ok, ClientSocket}},
            listen,
            #h2_listening_state{
               listen_socket = ListenSocket,
               listen_ref = Ref,
               transport = Transport,
               ssl_options = SSLOptions,
               acceptor_callback = AcceptorCallback,
               server_settings = Http2Settings
              }) ->

    %If anything crashes in here, at least there's another acceptor ready
    AcceptorCallback(),

    inet_db:register_socket(ClientSocket, inet_tcp),

    Socket = case Transport of
        gen_tcp ->
            ClientSocket;
        ssl ->
            {ok, AcceptSocket} = ssl:ssl_accept(ClientSocket, SSLOptions),
            {ok, <<"h2">>} = ssl:negotiated_protocol(AcceptSocket),
            AcceptSocket
    end,
    start_http2_server(
      Http2Settings,
      #connection{
         socket={Transport, Socket}
        });


%% Socket Messages
%% {tcp, Socket, Data}
handle_info({tcp, Socket, Data},
            StateName,
            #connection{
               socket={gen_tcp,Socket}
              }=Conn) ->
    handle_socket_data(Data, StateName, Conn);
%% {ssl, Socket, Data}
handle_info({ssl, Socket, Data},
            StateName,
            #connection{
               socket={ssl,Socket}
              }=Conn) ->
    handle_socket_data(Data, StateName, Conn);
%% {tcp_passive, Socket}
handle_info({tcp_passive, Socket},
            StateName,
            #connection{
               socket={gen_tcp, Socket}
              }=Conn) ->
    handle_socket_passive(StateName, Conn);
%% {tcp_closed, Socket}
handle_info({tcp_closed, Socket},
            StateName,
            #connection{
              socket={gen_tcp, Socket}
             }=Conn) ->
    handle_socket_closed(StateName, Conn);
%% {ssl_closed, Socket}
handle_info({ssl_closed, Socket},
            StateName,
            #connection{
               socket={ssl, Socket}
              }=Conn) ->
    handle_socket_closed(StateName, Conn);
%% {tcp_error, Socket, Reason}
handle_info({tcp_error, Socket, Reason},
            StateName,
            #connection{
               socket={gen_tcp,Socket}
              }=Conn) ->
    handle_socket_error(Reason, StateName, Conn);
%% {ssl_error, Socket, Reason}
handle_info({ssl_error, Socket, Reason},
            StateName,
            #connection{
               socket={ssl,Socket}
              }=Conn) ->
    handle_socket_error(Reason, StateName, Conn);
handle_info({_,R}=M, StateName,
           #connection{}=Conn) ->
    lager:error("[~p] BOOM! ~p", [Conn#connection.type, M]),
    handle_socket_error(R, StateName, Conn).

code_change(_OldVsn, StateName, Conn, _Extra) ->
    {ok, StateName, Conn}.

terminate(normal, _StateName, _Conn) ->
    ok;
terminate(Reason, _StateName, Conn=#connection{}) ->
    lager:debug("[~p] terminate reason: ~p~n",
                [Conn#connection.type, Reason]);
terminate(Reason, StateName, State) ->
    lager:debug("Crashed ~p ~p, ~p", [Reason, StateName, State]).

-spec go_away(error_code(), connection()) -> {next_state, closing, connection()}.
go_away(ErrorCode,
        #connection{
           next_available_stream_id=NAS
          }=Conn) ->
    GoAway = #goaway{
                last_stream_id=NAS, %% maybe not the best idea.
                error_code=ErrorCode
               },
    GoAwayBin = http2_frame:to_binary({#frame_header{
                                          stream_id=0
                                         }, GoAway}),
    socksend(Conn, GoAwayBin),
    gen_fsm:send_event(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    {next_state, closing, Conn}.

%% rst_stream/3 looks for a running process for the stream. If it
%% finds one, it delegates sending the rst_stream frame to it, but if
%% it doesn't, it seems like a waste to spawn one just to kill it
%% after sending that frame, so we send it from here.
-spec rst_stream(stream_id(), error_code(), connection()) ->
                        {next_state, connected, connection()}.
rst_stream(StreamId, ErrorCode, Conn) ->
    case get_stream(StreamId, Conn#connection.streams) of
        false ->
            RstStream = #rst_stream{error_code=ErrorCode},
            RstStreamBin = http2_frame:to_binary(
                             {#frame_header{
                                 stream_id=StreamId
                                },
                              RstStream}),
            sock:send(Conn#connection.socket, RstStreamBin);
        Stream ->
            http2_stream:rst_stream(Stream#stream.pid, ?PROTOCOL_ERROR)
    end,
    {next_state, connected, Conn}.

-spec send_settings(settings(), connection()) -> connection().
send_settings(SettingsToSend,
              #connection{
                 recv_settings=CurrentSettings,
                 settings_sent=SS
                }=Conn) ->
    Ref = make_ref(),
    Bin = http2_frame_settings:send(CurrentSettings, SettingsToSend),
    socksend(Conn, Bin),
    send_ack_timeout({Ref,SettingsToSend}),
    Conn#connection{
      settings_sent=queue:in({Ref, SettingsToSend}, SS)
     }.

-spec send_ack_timeout({reference(), settings()}) -> pid().
send_ack_timeout(SS) ->
    Self = self(),
    SendAck = fun() ->
                  lager:debug("Spawning ack timeout alarm clock: ~p + ~p", [Self, SS]),
                  timer:sleep(5000),
                  gen_fsm:send_all_state_event(Self, {check_settings_ack,SS})
              end,
    spawn_link(SendAck).

%% private socket handling
active_once(Socket) ->
    sock:setopts(Socket, [{active, once}]).

client_options(Transport, SSLOptions) ->
    ClientSocketOptions = [
                           binary,
                           {packet, raw},
                           {active, once}
                          ],
    case Transport of
        ssl ->
            [{alpn_advertised_protocols, [<<"h2">>]}|ClientSocketOptions ++ SSLOptions];
        gen_tcp ->
            ClientSocketOptions
    end.

start_http2_server(
  Http2Settings,
  #connection{
     socket=Socket
    }=Conn) ->
    lager:info("[server] StartHTTP2 settings: ~p",
               [Http2Settings]),

    case accept_preface(Socket) of
        ok ->
            ok = active_once(Socket),
            NewState =
                Conn#connection{
                  type=server,
                  next_available_stream_id=2,
                  flow_control=application:get_env(chatterbox, server_flow_control, auto)
                 },
            {next_state,
             handshake,
             send_settings(Http2Settings, NewState)
            };
        {error, invalid_preface} ->
            lager:debug("[server] Invalid Preface"),
            {next_state, closing, Conn}
    end.

%% We're going to iterate through the preface string until we're done
%% or hit a mismatch
accept_preface(Socket) ->
    accept_preface(Socket, <<?PREFACE>>).

accept_preface(_Socket, <<>>) ->
    ok;
accept_preface(Socket, <<Char:8,Rem/binary>>) ->
    case sock:recv(Socket, 1, 5000) of
        {ok, <<Char>>} ->
            accept_preface(Socket, Rem);
        _E ->
            sock:close(Socket),
            {error, invalid_preface}
    end.

%% Incoming data is a series of frames. With a passive socket we can just:
%% 1. read(9)
%% 2. turn that 9 into an http2 frame header
%% 3. use that header's length field L
%% 4. read(L), now we have a frame
%% 5. do something with it
%% 6. goto 1

%% Things will be different with an {active, true} socket, and also
%% different again with an {active, once} socket

%% with {active, true}, we'd have to maintain some kind of input queue
%% because it will be very likely that Data is not neatly just a frame

%% with {active, once}, we'd probably be in a situation where Data
%% starts with a frame header. But it's possible that we're here with
%% a partial frame left over from the last active stream

%% We're going to go with the {active, once} approach, because it
%% won't block the gen_server on Transport:read(L), but it will wake
%% up and do something every time Data comes in.

handle_socket_data(<<>>,
                   StateName,
                   #connection{
                      socket=Socket
                     }=Conn) ->
    active_once(Socket),
    {next_state, StateName, Conn};
handle_socket_data(Data,
                   StateName,
                   #connection{
                      socket=Socket,
                      buffer=Buffer
                     }=Conn) ->
    More =
        case sock:recv(Socket, 0, 1) of %% fail fast
            {ok, Rest} ->
                Rest;
            %% It's not really an error, it's what we want
            {error, timeout} ->
                <<>>;
            _ ->
                <<>>
    end,
    %% What is buffer?
    %% empty - nothing, yay
    %% {frame, frame_header(), binary()} - Frame Header processed, Payload not big enough
    %% {binary, binary()} - If we're here, it must mean that Bin was too small to even be a header
    ToParse = case Buffer of
        empty ->
            <<Data/binary,More/binary>>;
        {frame, FHeader, BufferBin} ->
            {FHeader, <<BufferBin/binary,Data/binary,More/binary>>};
        {binary, BufferBin} ->
            <<BufferBin/binary,Data/binary,More/binary>>
    end,
    %% Now that the buffer has been merged, it's best to make sure any
    %% further state references don't have one
    NewConn = Conn#connection{buffer=empty},

    case http2_frame:recv(ToParse) of
        %% We got a full frame, ship it off to the FSM
        {ok, Frame, Rem} ->
            gen_fsm:send_event(self(), {frame, Frame}),
            handle_socket_data(Rem, StateName, NewConn);
        %% Not enough bytes left to make a header :(
        {error, not_enough_header, Bin} ->
            %% This is a situation where more bytes should come soon,
            %% so let's switch back to active, once
            active_once(Socket),
            {next_state, StateName, NewConn#connection{buffer={binary, Bin}}};
        %% Not enough bytes to make a payload
        {error, not_enough_payload, Header, Bin} ->
            %% This too
            active_once(Socket),
            {next_state, StateName, NewConn#connection{buffer={frame, Header, Bin}}};
        {error, Code} ->
            go_away(Code, Conn)
    end.

handle_socket_passive(StateName, Conn) ->
    {next_state, StateName, Conn}.

handle_socket_closed(_StateName, Conn) ->
    {stop, normal, Conn}.

handle_socket_error(Reason, _StateName, Conn) ->
    {stop, Reason, Conn}.

socksend(#connection{
            socket=Socket,
            type=T
           }, Data) ->
    case sock:send(Socket, Data) of
        ok ->
            ok;
        {error, Reason} ->
            lager:debug("[~p] {error, ~p} sending, ~p", [T, Reason, Data]),
            {error, Reason}
    end.

%% Stream list operations. Warning: These are abusing the underlying
%% tuple structure of the record for efficiency's sake

-spec get_stream(stream_id(), [stream()]) -> stream() | false.
get_stream(Id, Streams) ->
    lists:keyfind(Id, 2, Streams).

-spec replace_stream(stream(), [stream()]) -> [stream()].
replace_stream(Stream, Streams) ->
    lists:keyreplace(Stream#stream.id, 2, Streams, Stream).

-spec sort_streams([stream()]) -> [stream()].
sort_streams(Streams) ->
    lists:keysort(2, Streams).

%-spec delete_stream(stream(), [stream()]) -> [stream()].
%delete_stream(S, Streams) ->
%    lists:keydelete(S#stream.id, 2, Streams).

-spec new_stream_(stream_id(), connection()) -> stream().
new_stream_(StreamId, Conn) ->
    new_stream_(StreamId, self(), Conn).

-spec new_stream_(stream_id(), pid(), connection()) -> stream().
new_stream_(StreamId, NotifyPid, Conn) ->
    lager:debug("Spawning new pid for stream ~p", [StreamId]),
    {ok, Pid} = http2_stream:start_link(
                  [
                   {stream_id, StreamId},
                   {connection, self()},
                   {notify_pid, NotifyPid},
                   {callback_module, Conn#connection.stream_callback_mod},
                   {socket, Conn#connection.socket}
                  ]),
    NewStream = #stream{
                   id = StreamId,
                   pid = Pid,
                   send_window_size=Conn#connection.send_settings#settings.initial_window_size,
                   recv_window_size=Conn#connection.recv_settings#settings.initial_window_size
                  },
    lager:debug("NewStream ~p", [NewStream]),
    NewStream.

-spec maybe_hpack(#continuation_state{}, connection()) ->
                         {next_state, atom(), connection()}.
maybe_hpack(Continuation, Conn)
  when Continuation#continuation_state.end_headers ->
    Stream = get_stream(Continuation#continuation_state.stream_id,
                        Conn#connection.streams),

    HeadersBin = http2_frame_headers:from_frames(
                   queue:to_list(Continuation#continuation_state.frames)),
    case hpack:decode(HeadersBin, Conn#connection.decode_context) of
        {error, compression_error} ->
            go_away(?COMPRESSION_ERROR, Conn);
        {ok, {Headers, NewDecodeContext}} ->
            case good_req_headers(Headers) of
                {error, Code} ->
                    rst_stream(Stream#stream.id, Code, Conn);
                ok ->
                    case Continuation#continuation_state.type of
                        headers ->
                            %% If this returns 'trailers' then it had better
                            %% also be end_stream
                            case {
                              http2_stream:recv_h(Stream#stream.pid, Headers),
                              Continuation#continuation_state.end_stream
                             } of
                                {trailers, false} ->
                                    rst_stream(Stream#stream.id, ?PROTOCOL_ERROR, Conn);
                                _ -> ok
                            end;
                        push_promise ->
                            Promised = get_stream(Continuation#continuation_state.promised_id,
                                                  Conn#connection.streams),
                            http2_stream:recv_pp(Promised#stream.pid, Headers)
                    end,
                    case Continuation#continuation_state.end_stream of
                        true ->
                            http2_stream:recv_es(Stream#stream.pid);
                        false ->
                            ok
                    end
            end,
            {next_state, connected,
             Conn#connection{
               decode_context=NewDecodeContext,
               continuation=undefined
              }}
    end;
maybe_hpack(Continuation, Conn) ->
    {next_state, continuation,
     Conn#connection{
       continuation = Continuation
      }}.

%% A set of headers is "good" if:
%% * No names contain uppercase letters
%% * No psuedoheaders are duplicated
%% * No psuedoheaders occur after a normal header
%% * Only acceptable psuedoheaders are:
%%     :method, :scheme, :authority, :path,

good_req_headers(Headers) ->
    case
        no_upper_names(Headers) andalso
        all_psuedos_first(Headers)
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

all_psuedos_first(Headers) ->
    Tail = lists:dropwhile(
             fun({<<$:, _/binary>>, _}) ->
                     true;
                (_) -> false
             end,
             Headers),
    no_psuedos_left(Tail).

no_psuedos_left(Headers) ->
    lists:all(
      fun({<<$:, _/binary>>, _}) ->
              false;
         (_) -> true
      end,
      Headers).
