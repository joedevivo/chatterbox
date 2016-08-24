-module(h2_connection).
-include("http2.hrl").
-behaviour(gen_fsm).

%% Start/Stop API
-export([
         start_client_link/5,
         start_ssl_upgrade_link/5,
         start_server_link/3,
         become/1,
         become/2,
         stop/1
        ]).

%% HTTP Operations
-export([
         send_headers/3,
         send_headers/4,
         send_body/3,
         send_body/4,
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
-export(
   [
    init/1,
    handle_event/3,
    handle_sync_event/4,
    handle_info/3,
    code_change/4,
    terminate/3
   ]).

%% gen_fsm states
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
          ssl_options   :: [ssl:ssl_option()],
          listen_socket :: ssl:sslsocket() | inet:socket(),
          transport     :: gen_tcp | ssl,
          listen_ref    :: non_neg_integer(),
          acceptor_callback = fun chatterbox_sup:start_socket/0 :: fun(),
          server_settings = #settings{} :: settings()
         }).

-record(continuation_state, {
          stream_id                 :: stream_id(),
          promised_id = undefined   :: undefined | stream_id(),
          frames      = queue:new() :: queue:queue(h2_frame:frame()),
          type                      :: headers | push_promise | trailers,
          end_stream  = false       :: boolean(),
          end_headers = false       :: boolean()
}).

-record(connection, {
          type = undefined :: client | server | undefined,
          ssl_options = [],
          listen_ref :: non_neg_integer(),
          socket = undefined :: sock:socket(),
          peer_settings = #settings{} :: settings(),
          self_settings = #settings{} :: settings(),
          send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          decode_context = hpack:new_context() :: hpack:context(),
          encode_context = hpack:new_context() :: hpack:context(),
          settings_sent = queue:new() :: queue:queue(),
          next_available_stream_id = 2 :: stream_id(),
          streams :: h2_stream_set:stream_set(),
          stream_callback_mod = application:get_env(chatterbox, stream_callback_mod, chatterbox_static_stream) :: module(),
          buffer = empty :: empty | {binary, binary()} | {frame, h2_frame:header(), binary()},
          continuation = undefined :: undefined | #continuation_state{},
          flow_control = auto :: auto | manual
}).

-type connection() :: #connection{}.

-type send_option() :: {send_end_stream, boolean()}.
-type send_opts() :: [send_option()].

-export_type([send_option/0, send_opts/0]).

-spec start_client_link(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:ssl_option()],
                        settings()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link(Transport, Host, Port, SSLOptions, Http2Settings) ->
    gen_fsm:start_link(?MODULE, {client, Transport, Host, Port, SSLOptions, Http2Settings}, []).

-spec start_ssl_upgrade_link(inet:ip_address() | inet:hostname(),
                             inet:port_number(),
                             binary(),
                             [ssl:ssl_option()],
                             settings()
                            ) ->
                                    {ok, pid()} | ignore | {error, term()}.
start_ssl_upgrade_link(Host, Port, InitialMessage, SSLOptions, Http2Settings) ->
    gen_fsm:start_link(?MODULE, {client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions, Http2Settings}, []).

-spec start_server_link(socket(),
                        [ssl:ssl_option()],
                        #settings{}) ->
                               {ok, pid()} | ignore | {error, term()}.
start_server_link({Transport, ListenSocket}, SSLOptions, Http2Settings) ->
    gen_fsm:start_link(?MODULE, {server, {Transport, ListenSocket}, SSLOptions, Http2Settings}, []).

-spec become(socket()) -> no_return().
become(Socket) ->
    become(Socket, chatterbox:settings(server)).

-spec become(socket(), settings()) -> no_return().
become({Transport, Socket}, Http2Settings) ->
    ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary]),
    {_, _, NewState} =
        start_http2_server(Http2Settings,
                           #connection{
                              streams = h2_stream_set:new(server),
                              socket = {Transport, Socket}
                             }),
    gen_fsm:enter_loop(?MODULE,
                       [],
                       handshake,
                       NewState).

%% Init callback
init({client, Transport, Host, Port, SSLOptions, Http2Settings}) ->
    {ok, Socket} = Transport:connect(Host, Port, client_options(Transport, SSLOptions)),
    ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary]),
    Transport:send(Socket, <<?PREFACE>>),
    InitialState =
        #connection{
           type = client,
           streams = h2_stream_set:new(client),
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
           streams = h2_stream_set:new(client),
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
    gen_fsm:send_all_state_event(Pid, {send_headers, StreamId, Headers, []}),
    ok.

-spec send_headers(pid(), stream_id(), hpack:headers(), send_opts()) -> ok.
send_headers(Pid, StreamId, Headers, Opts) ->
    gen_fsm:send_all_state_event(Pid, {send_headers, StreamId, Headers, Opts}),
    ok.

-spec send_body(pid(), stream_id(), binary()) -> ok.
send_body(Pid, StreamId, Body) ->
    gen_fsm:send_all_state_event(Pid, {send_body, StreamId, Body, []}),
    ok.
-spec send_body(pid(), stream_id(), binary(), send_opts()) -> ok.
send_body(Pid, StreamId, Body, Opts) ->
    gen_fsm:send_all_state_event(Pid, {send_body, StreamId, Body, Opts}),
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

-spec new_stream(pid(), pid()) ->
                        stream_id()
                      | {error, error_code()}.
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

-spec get_streams(pid()) -> h2_stream_set:stream_set().
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

-spec handshake(timeout|{frame, h2_frame:frame()}, connection()) ->
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
                [Conn#connection.type, h2_frame:format(Frame)]),
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
                [Conn#connection.type, h2_frame:format(Frame)]),
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
%% http2 stream processor (h2_stream:recv_frame)
-spec route_frame(
        h2_frame:frame() | {error, term()},
        connection()) ->
    {next_state,
     connected | continuation | closing ,
     connection()}.
%% Bad Length of frame, exceedes maximum allowed size
route_frame({#frame_header{length=L}, _},
            #connection{
               self_settings=#settings{max_frame_size=MFS}
              }=Conn)
    when L > MFS ->
    go_away(?FRAME_SIZE_ERROR, Conn);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Connection Level Frames
%%
%% Here we'll handle anything that belongs on stream 0.

%% SETTINGS, finally something that's ok on stream 0
%% This is the non-ACK case, where settings have actually arrived
route_frame({H, Payload},
            #connection{
               peer_settings=PS=#settings{
                                   initial_window_size=OldIWS,
                                   header_table_size=HTS
                                  },
               streams=Streams,
               encode_context=EncodeContext
              }=Conn)
    when H#frame_header.type == ?SETTINGS,
         ?NOT_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    lager:debug("[~p] Received SETTINGS",
               [Conn#connection.type]),
    %% Need a way of processing settings so I know which ones came in
    %% on this one payload.
    case h2_frame_settings:validate(Payload) of
        ok ->
            {settings, PList} = Payload,

            Delta =
                case proplists:get_value(?SETTINGS_INITIAL_WINDOW_SIZE, PList) of
                    undefined ->
                        lager:debug("[~p] IWS undefined", [Conn#connection.type]),
                        0;
                    NewIWS ->
                        lager:debug("old IWS: ~p new IWS: ~p", [OldIWS, NewIWS]),
                        NewIWS - OldIWS
                end,
            NewPeerSettings = h2_frame_settings:overlay(PS, Payload),
            %% We've just got connection settings from a peer. He have a
            %% couple of jobs to do here w.r.t. flow control

            %% If Delta != 0, we need to change every stream's
            %% send_window_size in the state open or
            %% half_closed_remote. We'll just send the message
            %% everywhere. It's up to them if they need to do
            %% anything.
            UpdatedStreams1 =
                h2_stream_set:update_all_send_windows(Delta, Streams),

            UpdatedStreams2 =
                case proplists:get_value(?SETTINGS_MAX_CONCURRENT_STREAMS, PList) of
                    undefined ->
                        UpdatedStreams1;
                    NewMax ->
                        h2_stream_set:update_my_max_active(NewMax, UpdatedStreams1)
                end,

            NewEncodeContext = hpack:new_max_table_size(HTS, EncodeContext),

            socksend(Conn, h2_frame_settings:ack()),
            lager:debug("[~p] Sent Settings ACK",
                        [Conn#connection.type]),
            {next_state, connected, Conn#connection{
                                      peer_settings=NewPeerSettings,
                                      %% Why aren't we updating send_window_size here? Section 6.9.2 of
                                      %% the spec says: "The connection flow-control window can only be
                                      %% changed using WINDOW_UPDATE frames.",
                                      encode_context=NewEncodeContext,
                                      streams=UpdatedStreams2
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
               self_settings=#settings{
                                initial_window_size=OldIWS
                               }
              }=Conn)
    when H#frame_header.type == ?SETTINGS,
         ?IS_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    lager:debug("[~p] Received SETTINGS ACK",
               [Conn#connection.type]),
    case queue:out(SS) of
        {{value, {_Ref, NewSettings}}, NewSS} ->

            UpdatedStreams1 =
                case NewSettings#settings.initial_window_size of
                    undefined ->
                        ok;
                    NewIWS ->
                        Delta = OldIWS - NewIWS,
                        h2_stream_set:update_all_recv_windows(Delta, Streams)
                end,

            UpdatedStreams2 =
                case NewSettings#settings.max_concurrent_streams of
                    undefined ->
                        UpdatedStreams1;
                    NewMax ->
                        h2_stream_set:update_their_max_active(NewMax, UpdatedStreams1)
                end,
            {next_state,
             connected,
             Conn#connection{
               streams=UpdatedStreams2,
               settings_sent=NewSS,
               self_settings=NewSettings
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
    Stream = h2_stream_set:get(StreamId, Streams),

    case h2_stream_set:type(Stream) of
        active ->
            case {
              h2_stream_set:recv_window_size(Stream) < L,
              Conn#connection.flow_control,
              L > 0
             } of
                {true, _, _} ->
                    lager:error("[~p][Stream ~p] Flow Control got ~p bytes, Stream window was ~p",
                                [
                                 Conn#connection.type,
                                 StreamId,
                                 L,
                                 h2_stream_set:recv_window_size(Stream)]
                               ),
                    rst_stream(Stream,
                               ?FLOW_CONTROL_ERROR,
                               Conn);
                %% If flow control is set to auto, and L > 0, send
                %% window updates back to the peer. If L == 0, we're
                %% not allowed to send window_updates of size 0, so we
                %% hit the next clause
                {false, auto, true} ->
                    %% Make window size great again
                    lager:info("[~p] Stream ~p WindowUpdate ~p",
                               [Conn#connection.type, StreamId, L]),
                    h2_frame_window_update:send(Conn#connection.socket,
                                                L, StreamId),
                    send_window_update(self(), L),
                    recv_data(Stream, F),
                    {next_state,
                     connected,
                     Conn};
                %% Either
                %% {false, auto, true} or
                %% {false, manual, _DoesntMatter}
                _Tried ->
                    recv_data(Stream, F),
                    {next_state,
                     connected,
                     Conn#connection{
                       recv_window_size=CRWS-L,
                       streams=h2_stream_set:upsert(
                                 h2_stream_set:decrement_recv_window(L, Stream),
                                 Streams)
                      }}
            end;
        _ ->
            go_away(?PROTOCOL_ERROR, Conn)
    end;

route_frame({#frame_header{type=?HEADERS}=FH, _Payload},
            #connection{}=Conn)
  when Conn#connection.type == server,
       FH#frame_header.stream_id rem 2 == 0 ->
    go_away(?PROTOCOL_ERROR, Conn);
route_frame({#frame_header{type=?HEADERS}=FH, _Payload}=Frame,
            #connection{}=Conn) ->
    StreamId = FH#frame_header.stream_id,
    Streams = Conn#connection.streams,

    lager:debug("[~p] Received HEADERS Frame for Stream ~p",
                [Conn#connection.type, StreamId]),

    %% Four things could be happening here.

    %% If we're a server, these are either request headers or request
    %% trailers

    %% If we're a client, these are either headers in response to a
    %% client request, or headers in response to a push promise

    Stream = h2_stream_set:get(StreamId, Streams),
    {ContinuationType, NewConn} =
        case {h2_stream_set:type(Stream), Conn#connection.type} of
            {idle, server} ->
                case
                    h2_stream_set:new_stream(
                      StreamId,
                      self(),
                      Conn#connection.stream_callback_mod,
                      Conn#connection.socket,
                      (Conn#connection.peer_settings)#settings.initial_window_size,
                      (Conn#connection.self_settings)#settings.initial_window_size,
                      Streams) of
                    {error, ErrorCode, NewStream} ->
                        rst_stream(NewStream, ErrorCode, Conn),
                        {none, Conn};
                    NewStreams ->
                        {headers, Conn#connection{streams=NewStreams}}
                end;
            {active, server} ->
                {trailers, Conn};
            _ ->
                {headers, Conn}
        end,

    case ContinuationType of
        none ->
            {next_state,
             connected,
             NewConn};
        _ ->
            ContinuationState =
                #continuation_state{
                   type = ContinuationType,
                   frames = queue:from_list([Frame]),
                   end_stream = ?IS_FLAG((FH#frame_header.flags), ?FLAG_END_STREAM),
                   end_headers = ?IS_FLAG((FH#frame_header.flags), ?FLAG_END_HEADERS),
                   stream_id = StreamId
                  },
            %% maybe_hpack/2 uses this #continuation_state to figure
            %% out what to do, which might include hpack
            maybe_hpack(ContinuationState, NewConn)
    end;

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
                  end_headers=?IS_FLAG((H#frame_header.flags), ?FLAG_END_HEADERS)
                 },
                Conn);

route_frame({H, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?PRIORITY,
         H#frame_header.stream_id == 0 ->
    go_away(?PROTOCOL_ERROR, Conn);
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
   Payload},
  #connection{} = Conn) ->
    EC = h2_frame_rst_stream:error_code(Payload),
    lager:debug("[~p] Received RST_STREAM (~p) for Stream ~p",
                [Conn#connection.type, EC, StreamId]),
    Streams = Conn#connection.streams,
    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        idle ->
            go_away(?PROTOCOL_ERROR, Conn);
        _Stream ->
            %% TODO: RST_STREAM support
            {next_state, connected, Conn}
    end;
route_frame({H=#frame_header{}, _P},
            #connection{} =Conn)
    when H#frame_header.type == ?PUSH_PROMISE,
         Conn#connection.type == server ->
    go_away(?PROTOCOL_ERROR, Conn);
route_frame({H=#frame_header{
                  stream_id=StreamId
                 },
             Payload}=Frame,
            #connection{}=Conn)
    when H#frame_header.type == ?PUSH_PROMISE,
         Conn#connection.type == client ->
    PSID = h2_frame_push_promise:promised_stream_id(Payload),
    lager:debug("[~p] Received PUSH_PROMISE Frame on Stream ~p for Stream ~p",
                [Conn#connection.type, StreamId, PSID]),

    Streams = Conn#connection.streams,

    Old = h2_stream_set:get(StreamId, Streams),
    NotifyPid = h2_stream_set:notify_pid(Old),

    %% TODO: Case statement here about execeding the number of
    %% pushed. Honestly I think it's a bigger problem with the
    %% h2_stream_set, but we can punt it for now. The idea is that
    %% reserved(local) and reserved(remote) aren't technically
    %% 'active', but they're being counted that way right now. Again,
    %% that only matters if Server Push is enabled.
    NewStreams =
        h2_stream_set:new_stream(
          PSID,
          NotifyPid,
          Conn#connection.stream_callback_mod,
          Conn#connection.socket,
          (Conn#connection.peer_settings)#settings.initial_window_size,
          (Conn#connection.self_settings)#settings.initial_window_size,
          Streams),

    Continuation = #continuation_state{
                      stream_id=StreamId,
                      type=push_promise,
                      frames = queue:in(Frame, queue:new()),
                      end_headers=?IS_FLAG((H#frame_header.flags), ?FLAG_END_HEADERS),
                      promised_id=PSID
                     },
    maybe_hpack(Continuation,
                Conn#connection{
                  streams = NewStreams
                 });
%% PING
%% If not stream 0, then connection error
route_frame({H, _Payload},
            #connection{} = Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.stream_id =/= 0 ->
    go_away(?PROTOCOL_ERROR, Conn);
%% If length != 8, FRAME_SIZE_ERROR
%% TODO: I think this case is already covered in h2_frame now
route_frame({H, _Payload},
           #connection{}=Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.length =/= 8 ->
    go_away(?FRAME_SIZE_ERROR, Conn);
%% If PING && !ACK, must ACK
route_frame({H, Ping},
            #connection{}=Conn)
    when H#frame_header.type == ?PING,
         ?NOT_FLAG((#frame_header.flags), ?FLAG_ACK) ->
    lager:debug("[~p] Received PING",
               [Conn#connection.type]),
    Ack = h2_frame_ping:ack(Ping),
    socksend(Conn, h2_frame:to_binary(Ack)),
    {next_state, connected, Conn};
route_frame({H, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?PING,
         ?IS_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    lager:debug("[~p] Received PING ACK",
               [Conn#connection.type]),
    {next_state, connected, Conn};
route_frame({H=#frame_header{stream_id=0}, _Payload},
            #connection{}=Conn)
    when H#frame_header.type == ?GOAWAY ->
    lager:debug("[~p] Received GOAWAY Frame for Stream 0",
               [Conn#connection.type]),
    go_away(?NO_ERROR, Conn);

%% Window Update
route_frame(
  {#frame_header{
      stream_id=0,
      type=?WINDOW_UPDATE
     },
   Payload},
  #connection{
     send_window_size=SWS
    }=Conn) ->
    WSI = h2_frame_window_update:size_increment(Payload),
    lager:debug("[~p] Stream 0 Window Update: ~p",
                [Conn#connection.type, WSI]),
    NewSendWindow = SWS+WSI,
    case NewSendWindow > 2147483647 of
        true ->
            go_away(?FLOW_CONTROL_ERROR, Conn);
        false ->
            %% TODO: Priority Sort! Right now, it's just sorting on
            %% lowest stream_id first
            Streams = h2_stream_set:sort(Conn#connection.streams),

            {RemainingSendWindow, UpdatedStreams} =
                h2_stream_set:send_what_we_can(
                  all,
                  NewSendWindow,
                  (Conn#connection.peer_settings)#settings.max_frame_size,
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
   Payload},
  #connection{}=Conn
 ) ->
    StreamId = FH#frame_header.stream_id,
    Streams = Conn#connection.streams,
    WSI = h2_frame_window_update:size_increment(Payload),
    lager:debug("[~p] Received WINDOW_UPDATE Frame for Stream ~p",
                [Conn#connection.type, StreamId]),
    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        idle ->
            lager:error("[~p] Window update for an idle stream (~p)",
                       [Conn#connection.type, StreamId]),
            go_away(?PROTOCOL_ERROR, Conn);
        closed ->
            rst_stream(Stream, ?STREAM_CLOSED, Conn);
        active ->
            SWS = Conn#connection.send_window_size,
            NewSSWS = h2_stream_set:send_window_size(Stream)+WSI,

            case NewSSWS > 2147483647 of
                true ->
                    lager:error("Sending ~p FLOWCONTROL ERROR because NSW = ~p", [StreamId, NewSSWS]),
                    rst_stream(Stream, ?FLOW_CONTROL_ERROR, Conn);
                false ->
                    lager:debug("Stream ~p send window now: ~p", [StreamId, NewSSWS]),
                    {RemainingSendWindow, NewStreams}
                        = h2_stream_set:send_what_we_can(
                            StreamId,
                            SWS,
                            (Conn#connection.peer_settings)#settings.max_frame_size,
                            h2_stream_set:upsert(
                              h2_stream_set:increment_send_window_size(WSI, Stream),
                              Streams)
                           ),
                    {next_state, connected,
                     Conn#connection{
                       send_window_size=RemainingSendWindow,
                       streams=NewStreams
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
    lager:error("OOPS! " ++ h2_frame:format(Frame)),
    lager:error("OOPS! ~p", [Conn]),
    go_away(?PROTOCOL_ERROR, Conn).

handle_event({stream_finished,
              StreamId,
              Headers,
              Body}, StateName,
             Conn) ->
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    case h2_stream_set:type(Stream) of
        active ->
            NotifyPid = h2_stream_set:notify_pid(Stream),
            Response =
                case Conn#connection.type of
                    server -> garbage;
                    client -> {Headers, Body}
                end,
            {_NewStream, NewStreams} =
                h2_stream_set:close(
                  Stream,
                  Response,
                  Conn#connection.streams),

            NewConn =
                Conn#connection{
                  streams = NewStreams
                 },
            case {Conn#connection.type, is_pid(NotifyPid)} of
                {client, true} ->
                    NotifyPid ! {'END_STREAM', StreamId};
                _ ->
                    ok
            end,
            {next_state, StateName, NewConn};
        _ ->
            lager:error("[~p] stream ~p finished multiple times",
                        [Conn#connection.type,
                         StreamId]),
            {next_state, StateName, Conn}
    end;
handle_event({send_window_update, 0},
             StateName, Conn) ->
    {next_state, StateName, Conn};
handle_event({send_window_update, Size},
             StateName,
             #connection{
                recv_window_size=CRWS,
                socket=Socket
                }=Conn) ->
    ok = h2_frame_window_update:send(Socket, Size, 0),
    {next_state,
     StateName,
     Conn#connection{
       recv_window_size=CRWS+Size
      }};
handle_event({send_headers, StreamId, Headers, Opts},
             StateName,
             #connection{
                encode_context=EncodeContext,
                streams = Streams,
                socket = Socket
               }=Conn
            ) ->
    lager:debug("[~p] {send headers, ~p, ~p}",
                [Conn#connection.type, StreamId, Headers]),
    StreamComplete = proplists:get_value(send_end_stream, Opts, false),

    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        active ->
            {FramesToSend, NewContext} =
                h2_frame_headers:to_frames(h2_stream_set:stream_id(Stream),
                                           Headers,
                                           EncodeContext,
                                            (Conn#connection.peer_settings)#settings.max_frame_size,
                                           StreamComplete
                                          ),
            [sock:send(Socket, h2_frame:to_binary(Frame)) || Frame <- FramesToSend],
            send_h(Stream, Headers),
            {next_state, StateName,
             Conn#connection{
               encode_context=NewContext
              }};
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            {next_state, StateName, Conn};
        closed ->
            {next_state, StateName, Conn}
    end;

handle_event({send_body, StreamId, Body, Opts},
             StateName,
             #connection{}=Conn) ->
    lager:debug("[~p] Send Body Stream ~p",
                [Conn#connection.type, StreamId]),
    BodyComplete = proplists:get_value(send_end_stream, Opts, true),

    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    case h2_stream_set:type(Stream) of
        active ->
            OldBody = h2_stream_set:queued_data(Stream),
            NewBody = case is_binary(OldBody) of
                          true -> <<OldBody/binary, Body/binary>>;
                          false -> Body
                      end,
            {NewSWS, NewStreams} =
                h2_stream_set:send_what_we_can(
                  StreamId,
                  Conn#connection.send_window_size,
                  (Conn#connection.peer_settings)#settings.max_frame_size,
                  h2_stream_set:upsert(
                    h2_stream_set:update_data_queue(NewBody, BodyComplete, Stream),
                    Conn#connection.streams)),

            {next_state, StateName,
             Conn#connection{
               send_window_size=NewSWS,
               streams=NewStreams
              }};
        idle ->
            %% Sending DATA frames on an idle stream?  It's a
            %% Connection level protocol error on reciept, but If we
            %% have no active stream what can we even do?
            lager:info("[~p] tried sending data on idle stream ~p",
                       [Conn#connection.type, StreamId]),
            {next_state, StateName, Conn};
        closed ->
            {next_state, StateName, Conn}
    end;

handle_event({send_promise, StreamId, NewStreamId, Headers},
             StateName,
             #connection{
                streams=Streams,
                encode_context=OldContext
               }=Conn
            ) ->
    NewStream = h2_stream_set:get(NewStreamId, Streams),
    case h2_stream_set:type(NewStream) of
        active ->
            %% TODO: This could be a series of frames, not just one
            {PromiseFrame, NewContext} =
                h2_frame_push_promise:to_frame(
               StreamId,
               NewStreamId,
               Headers,
               OldContext
              ),

            %% Send the PP Frame
            Binary = h2_frame:to_binary(PromiseFrame),
            socksend(Conn, Binary),

            %% Get the promised stream rolling
            h2_stream:send_pp(h2_stream_set:stream_pid(NewStream), Headers),

            {next_state, StateName,
             Conn#connection{
               encode_context=NewContext
              }};
        _ ->
            {next_state, StateName, Conn}
    end;

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
    Binary = h2_frame:to_binary(Frame),
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
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    Reply = case h2_stream_set:type(Stream) of
                closed ->
                    {ok, h2_stream_set:response(Stream)};
                active ->
                    not_ready
            end,
    {reply, Reply, StateName, Conn};
handle_sync_event({new_stream, NotifyPid}, _F, StateName,
                  #connection{
                     streams=Streams,
                     next_available_stream_id=NextId
                    }=Conn) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              NextId,
              NotifyPid,
              Conn#connection.stream_callback_mod,
              Conn#connection.socket,
              Conn#connection.peer_settings#settings.initial_window_size,
              Conn#connection.self_settings#settings.initial_window_size,
              Streams)
        of
            {error, Code, _NewStream} ->
                lager:warning("[~p] tried to create new_stream ~p, but there are too many",
                              [Conn#connection.type, NextId]),
                {{error, Code}, Streams};
            GoodStreamSet ->
                lager:debug("[~p] added stream #~p to ~p",
                            [Conn#connection.type, NextId, GoodStreamSet]),
                {NextId, GoodStreamSet}
        end,
    {reply, Reply, StateName, Conn#connection{
                                 next_available_stream_id=NextId+2,
                                 streams=NewStreams
                                }};
handle_sync_event(is_push, _F, StateName,
                  #connection{
                     peer_settings=#settings{enable_push=Push}
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
         streams = h2_stream_set:new(server),
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
    GoAway = h2_frame_goaway:new(NAS, ErrorCode),
    GoAwayBin = h2_frame:to_binary({#frame_header{
                                       stream_id=0
                                      }, GoAway}),
    socksend(Conn, GoAwayBin),
    gen_fsm:send_event(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    {next_state, closing, Conn}.

%% rst_stream/3 looks for a running process for the stream. If it
%% finds one, it delegates sending the rst_stream frame to it, but if
%% it doesn't, it seems like a waste to spawn one just to kill it
%% after sending that frame, so we send it from here.
-spec rst_stream(
        h2_stream_set:stream(),
        error_code(),
        connection()
       ) ->
                        {next_state, connected, connection()}.
rst_stream(Stream, ErrorCode, Conn) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% Can this ever be undefined?
            Pid = h2_stream_set:stream_pid(Stream),
            %% h2_stream's rst_stream will take care of letting us know
            %% this stream is closed and will send us a message to close the
            %% stream somewhere else
            h2_stream:rst_stream(Pid, ErrorCode),
            {next_state, connected, Conn};
        _ ->
            StreamId = h2_stream_set:stream_id(Stream),
            RstStream = h2_frame_rst_stream:new(ErrorCode),
            RstStreamBin = h2_frame:to_binary(
                          {#frame_header{
                              stream_id=StreamId
                             },
                           RstStream}),
            sock:send(Conn#connection.socket, RstStreamBin),
            {next_state, connected, Conn}
    end.

-spec send_settings(settings(), connection()) -> connection().
send_settings(SettingsToSend,
              #connection{
                 self_settings=CurrentSettings,
                 settings_sent=SS
                }=Conn) ->
    Ref = make_ref(),
    Bin = h2_frame_settings:send(CurrentSettings, SettingsToSend),
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
    %% {frame, h2_frame:header(), binary()} - Frame Header processed, Payload not big enough
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

    case h2_frame:recv(ToParse) of
        %% We got a full frame, ship it off to the FSM
        {ok, Frame, Rem} ->
            gen_fsm:send_event(self(), {frame, Frame}),
            handle_socket_data(Rem, StateName, NewConn);
        %% Not enough bytes left to make a header :(
        {not_enough_header, Bin} ->
            %% This is a situation where more bytes should come soon,
            %% so let's switch back to active, once
            active_once(Socket),
            {next_state, StateName, NewConn#connection{buffer={binary, Bin}}};
        %% Not enough bytes to make a payload
        {not_enough_payload, Header, Bin} ->
            %% This too
            active_once(Socket),
            {next_state, StateName, NewConn#connection{buffer={frame, Header, Bin}}};
        {error, 0, Code, _Rem} ->
            %% Remaining Bytes don't matter, we're closing up shop.
            go_away(Code, NewConn);
        {error, StreamId, Code, Rem} ->
            Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
            rst_stream(Stream, Code, NewConn),
            handle_socket_data(Rem, StateName, NewConn)
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

%% maybe_hpack will decode headers if it can, or tell the connection
%% to wait for CONTINUATION frames if it can't.
-spec maybe_hpack(#continuation_state{}, connection()) ->
                         {next_state, atom(), connection()}.
%% If there's an END_HEADERS flag, we have a complete headers binary
%% to decode, let's do this!
maybe_hpack(Continuation, Conn)
  when Continuation#continuation_state.end_headers ->
    Stream = h2_stream_set:get(
               Continuation#continuation_state.stream_id,
               Conn#connection.streams
              ),
    HeadersBin = h2_frame_headers:from_frames(
                queue:to_list(Continuation#continuation_state.frames)
               ),
    case hpack:decode(HeadersBin, Conn#connection.decode_context) of
        {error, compression_error} ->
            go_away(?COMPRESSION_ERROR, Conn);
        {ok, {Headers, NewDecodeContext}} ->
            case {Continuation#continuation_state.type,
                  Continuation#continuation_state.end_stream} of
                {push_promise, _} ->
                    Promised =
                        h2_stream_set:get(
                          Continuation#continuation_state.promised_id,
                          Conn#connection.streams
                         ),
                    recv_pp(Promised, Headers);
                {trailers, false} ->
                    rst_stream(Stream, ?PROTOCOL_ERROR, Conn);
                _ -> %% headers or trailers!
                    recv_h(Stream, Conn, Headers)
            end,
            case Continuation#continuation_state.end_stream of
                true ->
                    recv_es(Stream, Conn);
                false ->
                    ok
            end,
            {next_state, connected,
             Conn#connection{
               decode_context=NewDecodeContext,
               continuation=undefined
              }}
    end;
%% If not, we have to wait for all the CONTINUATIONS to roll in.
maybe_hpack(Continuation, Conn) ->
    {next_state, continuation,
     Conn#connection{
       continuation = Continuation
      }}.

%% Stream API: These will be moved
-spec recv_h(
        Stream :: h2_stream_set:stream(),
        Conn :: connection(),
        Headers :: hpack:headers()) ->
                    ok.
recv_h(Stream,
       Conn,
       Headers) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% If the stream is active, let the process deal with it.
            Pid = h2_stream_set:pid(Stream),
            gen_fsm:send_event(Pid, {recv_h, Headers});
        closed ->
            %% If the stream is closed, there's no running FSM
            rst_stream(Stream, ?STREAM_CLOSED, Conn);
        idle ->
            %% If we're calling this function, we've already activated
            %% a stream FSM (probably). On the off chance we didn't,
            %% we'll throw this
            rst_stream(Stream, ?STREAM_CLOSED, Conn)
    end.

-spec send_h(
        h2_stream_set:stream(),
        hpack:headers()) ->
                    ok.
send_h(Stream, Headers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% Should this be some kind of error?
            lager:info("tried sending headers on a non running stream ~p",
                       [h2_stream_set:stream_id(Stream)]),
            ok;
        Pid ->
            gen_fsm:send_event(Pid, {send_h, Headers})
    end.

-spec recv_es(Stream :: h2_stream_set:stream(),
              Conn :: connection()) ->
                     ok | {rst_stream, error_code()}.

recv_es(Stream, Conn) ->
    case h2_stream_set:type(Stream) of
        active ->
            Pid = h2_stream_set:pid(Stream),
            gen_fsm:send_event(Pid, recv_es);
        closed ->
            rst_stream(Stream, ?STREAM_CLOSED, Conn);
        idle ->
            rst_stream(Stream, ?STREAM_CLOSED, Conn)
    end.

-spec recv_pp(h2_stream_set:stream(),
              hpack:headers()) ->
                     ok.
recv_pp(Stream, Headers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% Should this be an error?
            ok;
        Pid ->
            gen_fsm:send_event(Pid, {recv_pp, Headers})
    end.

-spec recv_data(h2_stream_set:stream(),
                h2_frame:frame()) ->
                        ok.
recv_data(Stream, Frame) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% Again, error? These aren't errors now because the code
            %% isn't set up to handle errors when these are called
            %% anyway.
            ok;
        Pid ->
            gen_fsm:send_event(Pid, {recv_data, Frame})
    end.
