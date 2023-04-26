-module(h2_connection).
-include("http2.hrl").
-behaviour(gen_statem).

%% Start/Stop API
-export([
         start_client/2,
         start_client/6,
         start_client_link/2,
         start_client_link/6,
         start_ssl_upgrade_link/6,
         start_server_link/3,
         become/1,
         become/2,
         become/3,
         stop/1
        ]).

%% HTTP Operations
-export([
         send_headers/3,
         send_headers/4,
         send_trailers/3,
         send_trailers/4,
         actually_send_trailers/3,
         send_body/3,
         send_body/4,
         send_request/3,
         send_request/5,
         send_ping/1,
         is_push/1,
         new_stream/3,
         new_stream/6,
         new_stream/7,
         send_promise/3,
         get_response/2,
         get_peer/1,
         get_peercert/1,
         get_streams/1,
         send_window_update/2,
         update_settings/2,
         send_frame/2,
         rst_stream/3
        ]).

%% gen_statem callbacks
-export(
   [
    init/1,
    callback_mode/0,
    code_change/4,
    terminate/3
   ]).

%% gen_statem states
-export([
         listen/3,
         handshake/3,
         connected/3,
         continuation/3,
         closing/3
        ]).

-export([
         go_away/3
        ]).

-record(h2_listening_state, {
          ssl_options   :: [ssl:tls_option()],
          listen_socket :: ssl:sslsocket() | inet:socket(),
          transport     :: gen_tcp | ssl,
          listen_ref    :: non_neg_integer(),
          acceptor_callback = fun chatterbox_sup:start_socket/0 :: fun(),
          server_settings = #settings{} :: settings()
         }).

-record(continuation_state, {
          stream_id                 :: stream_id(),
          promised_id = undefined   :: undefined | stream_id(),
          frames      = []          :: [h2_frame:frame()],
          type                      :: headers | push_promise | trailers,
          end_stream  = false       :: boolean(),
          end_headers = false       :: boolean()
}).

-record(connection, {
          type = undefined :: client | server | undefined,
          receiver :: pid() | undefined,
          ssl_options = [],
          listen_ref :: non_neg_integer() | undefined,
          socket = undefined :: sock:socket(),
          settings_sent = queue:new() :: queue:queue(),
          streams :: h2_stream_set:stream_set(),
          buffer = empty :: empty | {binary, binary()} | {frame, h2_frame:header(), binary()},
          continuation = undefined :: undefined | #continuation_state{},
          pings = #{} :: #{binary() => {pid(), non_neg_integer()}},
          %% if true then set a stream as garbage in the stream_set
          garbage_on_end = false :: boolean()
}).

-define(HIBERNATE_AFTER_DEFAULT_MS, infinity).

-type connection() :: #connection{}.

-type send_option() :: {send_end_stream, boolean()}.
-type send_opts() :: [send_option()].

-export_type([send_option/0, send_opts/0]).

-ifdef(OTP_RELEASE).
-define(ssl_accept(ClientSocket, SSLOptions), ssl:handshake(ClientSocket, SSLOptions)).
-else.
-define(ssl_accept(ClientSocket, SSLOptions), ssl:ssl_accept(ClientSocket, SSLOptions)).
-endif.

-spec start_client_link(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:tls_option()],
                        settings(),
                        map()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link(Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings) ->
    HibernateAfterTimeout = maps:get(hibernate_after, ConnectionSettings, ?HIBERNATE_AFTER_DEFAULT_MS),
    gen_statem:start_link(?MODULE, {client, Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_client(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:tls_option()],
                        settings(),
                        map()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client(Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings) ->
    HibernateAfterTimeout = maps:get(hibernate_after, ConnectionSettings, ?HIBERNATE_AFTER_DEFAULT_MS),
    gen_statem:start(?MODULE, {client, Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_client_link(socket(),
                        settings()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link({Transport, Socket}, Http2Settings) ->
    HibernateAfterTimeout = ?HIBERNATE_AFTER_DEFAULT_MS,
    gen_statem:start_link(?MODULE, {client, {Transport, Socket}, Http2Settings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_client(socket(),
                        settings()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client({Transport, Socket}, Http2Settings) ->
    HibernateAfterTimeout = ?HIBERNATE_AFTER_DEFAULT_MS,
    gen_statem:start(?MODULE, {client, {Transport, Socket}, Http2Settings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_ssl_upgrade_link(inet:ip_address() | inet:hostname(),
                             inet:port_number(),
                             binary(),
                             [ssl:tls_option()],
                             settings(),
                             map()
                            ) ->
                                    {ok, pid()} | ignore | {error, term()}.
start_ssl_upgrade_link(Host, Port, InitialMessage, SSLOptions, Http2Settings, ConnectionSettings) ->
    HibernateAfterTimeout = maps:get(hibernate_after, ConnectionSettings, ?HIBERNATE_AFTER_DEFAULT_MS),
    gen_statem:start_link(?MODULE, {client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions, Http2Settings, ConnectionSettings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec start_server_link(socket(),
                        [ssl:tls_option()],
                        settings()) ->
                               {ok, pid()} | ignore | {error, term()}.
start_server_link({Transport, ListenSocket}, SSLOptions, Http2Settings) ->
    HibernateAfterTimeout = ?HIBERNATE_AFTER_DEFAULT_MS,
    gen_statem:start_link(?MODULE, {server, {Transport, ListenSocket}, SSLOptions, Http2Settings}, [{hibernate_after, HibernateAfterTimeout}]).

-spec become(socket()) -> no_return().
become(Socket) ->
    become(Socket, chatterbox:settings(server)).

-spec become(socket(), settings()) -> no_return().
become(Socket, Http2Settings) ->
    become(Socket, Http2Settings, #{}).

-spec become(socket(), settings(), map()) -> no_return().
become({Transport, Socket}, Http2Settings, ConnectionSettings) ->
    ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary]),
    CallbackMod = maps:get(stream_callback_mod, ConnectionSettings,
                           application:get_env(chatterbox, stream_callback_mod, chatterbox_static_stream)),
    CallbackOpts = maps:get(stream_callback_opts, ConnectionSettings,
                            application:get_env(chatterbox, stream_callback_opts, [])),

    case start_http2_server(Http2Settings,
                           #connection{
                              streams = h2_stream_set:new(server, {Transport, Socket}, CallbackMod, CallbackOpts),
                              socket = {Transport, Socket}
                             }) of
        {_, handshake, NewState} ->
            gen_statem:enter_loop(?MODULE,
                                  [],
                                  handshake,
                                  NewState);
        {_, closing, _NewState} ->
            sock:close({Transport, Socket}),
            exit(normal)
    end.

%% Init callback
init({client, Transport, Host, Port, SSLOptions, Http2Settings, ConnectionSettings}) ->
    ConnectTimeout = maps:get(connect_timeout, ConnectionSettings, 5000),
    TcpUserTimeout = maps:get(tcp_user_timeout, ConnectionSettings, 0),
    SocketOptions = maps:get(socket_options, ConnectionSettings, []),
    case Transport:connect(Host, Port, client_options(Transport, SSLOptions, SocketOptions), ConnectTimeout) of
        {ok, Socket} ->
            ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary, {active, false}]),
            case TcpUserTimeout of
                0 -> ok;
                _ -> sock:setopts({Transport, Socket}, [{raw,6,18,<<TcpUserTimeout:32/native>>}])
            end,
            Transport:send(Socket, <<?PREFACE>>),
            Flow = application:get_env(chatterbox, client_flow_control, auto),
            CallbackMod = maps:get(stream_callback_mod, ConnectionSettings, undefined),
            CallbackOpts = maps:get(stream_callback_opts, ConnectionSettings, []),
            Streams = h2_stream_set:new(client, {Transport, Socket}, CallbackMod, CallbackOpts),
            Receiver = spawn_data_receiver({Transport, Socket}, Streams, Flow),
            InitialState =
                #connection{
                   type = client,
                   receiver=Receiver,
                   garbage_on_end = maps:get(garbage_on_end, ConnectionSettings, false),
                   streams = Streams,
                   socket = {Transport, Socket}
                  },
            {ok,
             handshake,
             send_settings(Http2Settings, InitialState),
             4500};
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end;
init({client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions, Http2Settings, ConnectionSettings}) ->
    ConnectTimeout = maps:get(connect_timeout, ConnectionSettings, 5000),
    SocketOptions = maps:get(socket_options, ConnectionSettings, []),
    case gen_tcp:connect(Host, Port, [{active, false}], ConnectTimeout) of
        {ok, TCP} ->
            gen_tcp:send(TCP, InitialMessage),
            case ssl:connect(TCP, client_options(ssl, SSLOptions, SocketOptions)) of
                {ok, Socket} ->
                    ok = ssl:setopts(Socket, [{packet, raw}, binary, {active, false}]),
                    ssl:send(Socket, <<?PREFACE>>),
                    CallbackMod = maps:get(stream_callback_mod, ConnectionSettings, undefined),
                    CallbackOpts = maps:get(stream_callback_opts, ConnectionSettings, []),
                    Streams = h2_stream_set:new(client, {ssl, Socket}, CallbackMod, CallbackOpts),
                    Flow = application:get_env(chatterbox, client_flow_control, auto),
                    Receiver = spawn_data_receiver({ssl, Socket}, Streams, Flow),
                    InitialState =
                        #connection{
                           type = client,
                           receiver=Receiver,
                           garbage_on_end = maps:get(garbage_on_end, ConnectionSettings, false),
                           streams = Streams,
                           socket = {ssl, Socket}
                          },
                    {ok,
                     handshake,
                     send_settings(Http2Settings, InitialState),
                     4500};
                {error, Reason} ->
                    {stop, {shutdown, Reason}}
            end;
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end;
init({server, {Transport, ListenSocket}, SSLOptions, Http2Settings}) ->
    %% prim_inet:async_accept is dope. It says just hang out here and
    %% wait for a message that a client has connected. That message
    %% looks like:
    %% {inet_async, ListenSocket, Ref, {ok, ClientSocket}}
    case prim_inet:async_accept(ListenSocket, -1) of
        {ok, Ref} ->
            {ok,
             listen,
             #h2_listening_state{
                ssl_options = SSLOptions,
                listen_socket = ListenSocket,
                listen_ref = Ref,
                transport = Transport,
                server_settings = Http2Settings
               }}; %% No timeout here, it's just a listener
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end.

callback_mode() ->
    state_functions.

send_frame(Pid, Bin)
  when is_binary(Bin); is_list(Bin) ->
    gen_statem:cast(Pid, {send_bin, Bin});
send_frame(Pid, Frame) ->
    gen_statem:cast(Pid, {send_frame, Frame}).

-spec send_headers(h2_stream_set:stream_set(), stream_id(), hpack:headers()) -> ok.
send_headers(Pid, StreamId, Headers) ->
    send_headers_(StreamId, Headers, [], Pid).

-spec send_headers(h2_stream_set:stream_set(), stream_id(), hpack:headers(), send_opts()) -> ok.
send_headers(Pid, StreamId, Headers, Opts) ->
    send_headers_(StreamId, Headers, Opts, Pid).

-spec rst_stream(h2_stream_set:stream_set(), stream_id(), error_code()) -> ok.
rst_stream(Streams, StreamId, ErrorCode) ->
    Stream = h2_stream_set:get(StreamId, Streams),
    rst_stream__(Stream, ErrorCode, h2_stream_set:socket(Streams)).

-spec send_trailers(h2_stream_set:stream_set(), stream_id(), hpack:headers()) -> ok.
send_trailers(Streams, StreamId, Trailers) ->
    send_trailers_(StreamId, Trailers, [], Streams).

-spec send_trailers(h2_stream_set:stream_set(), stream_id(), hpack:headers(), send_opts()) -> ok.
send_trailers(Streams, StreamId, Trailers, Opts) ->
    send_trailers_(StreamId, Trailers, Opts, Streams).

actually_send_trailers(Streams, StreamId, Trailers) ->
    EncodeContext0 = h2_stream_set:get_encode_context(Streams),
    Locks = case hpack:all_fields_indexed(Trailers, EncodeContext0) of
                true ->
                    [socket];
                false ->
                    [socket, encoder]
            end,
    h2_stream_set:take_exclusive_lock(Streams, Locks,
                                      fun() ->
                                              Stream = h2_stream_set:get(StreamId, Streams),
                                              EncodeContext = h2_stream_set:get_encode_context(Streams),
                                              {_SelfSettings, PeerSettings} = h2_stream_set:get_settings(Streams),
                                              {FramesToSend, NewContext} =
                                              h2_frame_headers:to_frames(h2_stream_set:stream_id(Stream),
                                                                         Trailers,
                                                                         EncodeContext,
                                                                         PeerSettings#settings.max_frame_size,
                                                                         true
                                                                        ),
                                              case Locks of
                                                  [] ->
                                                      ok;
                                                  _ ->
                                                      h2_stream_set:update_encode_context(Streams, NewContext)
                                              end,

                                              sock:send(h2_stream_set:socket(Streams), [h2_frame:to_binary(Frame) || Frame <- FramesToSend]),
                                              ok
                                      end).

-spec send_body(h2_stream_set:stream_set(), stream_id(), binary()) -> ok.
send_body(Pid, StreamId, Body) ->
    send_body_(StreamId, Body, [], Pid).

-spec send_body(h2_stream_set:stream_set(), stream_id(), binary(), send_opts()) -> ok.
send_body(Pid, StreamId, Body, Opts) ->
    send_body_(StreamId, Body, Opts, Pid).

-spec send_request(h2_stream_set:stream_set(), hpack:headers(), binary()) -> ok.
send_request(Streams, Headers, Body) ->
    {CallbackMod, CallbackOpts} = h2_stream_set:get_callback(Streams),
    send_request(Streams, Headers, Body, CallbackMod, CallbackOpts).

-spec send_request(h2_stream_set:stream_set(), hpack:headers(), binary(), atom(), list()) -> ok.
send_request(Streams, Headers, Body, CallbackMod, CallbackOpts) ->
    gen_server:call(h2_stream_set:connection(Streams), {new_stream, CallbackMod, CallbackOpts, Headers, Body, [], self()}).

-spec send_ping(h2_stream_set:stream_set()) -> ok.
send_ping(Streams) ->
    Pid = h2_stream_set:connection(Streams),
    gen_statem:call(Pid, {send_ping, self()}, infinity),
    ok.

-spec get_peer(h2_stream_set:stream_set()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
get_peer(Streams) ->
    Pid = h2_stream_set:connection(Streams),
    gen_statem:call(Pid, get_peer).

-spec get_peercert(h2_stream_set:stream_set()) ->
    {ok, binary()} | {error, term()}.
get_peercert(Streams) ->
    Pid = h2_stream_set:connection(Streams),
    gen_statem:call(Pid, get_peercert).

-spec is_push(h2_stream_set:stream_set()) -> boolean().
is_push(Streams) ->
    {_SelfSettings, #settings{enable_push=Push}} = h2_stream_set:get_settings(Streams),
    case Push of
        1 -> true;
        _ -> false
    end.

new_stream(Streams, Headers, Body) ->
    gen_server:call(h2_stream_set:connection(Streams), {new_stream, undefined, [], Headers, Body, [], self()}).

%% @doc `new_stream/6' accepts Headers so they can be sent within the connection process
%% when a stream id is assigned. This ensures that another process couldn't also have
%% requested a new stream and send its headers before the stream with a lower id, which
%% results in the server closing the connection when it gets headers for the lower id stream.
-spec new_stream(h2_stream_set:stream_set(), module(), term(), hpack:headers(), send_opts(), pid()) -> {stream_id(), pid()} | {error, error_code()}.
new_stream(Streams, CallbackMod, CallbackOpts, Headers, Opts, NotifyPid) ->
    gen_server:call(h2_stream_set:connection(Streams), {new_stream, CallbackMod, CallbackOpts, Headers, Opts, NotifyPid}).

-spec new_stream(h2_stream_set:stream_set(), module(), term(), hpack:headers(), any(), send_opts(), pid()) -> {stream_id(), pid()} | {error, error_code()}.
new_stream(Streams, CallbackMod, CallbackOpts, Headers, Body, Opts, NotifyPid) ->
    gen_server:call(h2_stream_set:connection(Streams), {new_stream, CallbackMod, CallbackOpts, Headers, Body, Opts, NotifyPid}).

-spec send_promise(h2_stream_set:stream_set(), stream_id(), hpack:headers()) -> {stream_id(), pid()} | {error, error_code()}.
send_promise(Streams, StreamId, Headers) ->
    gen_server:call(h2_stream_set:connection(Streams), {send_promise, StreamId, Headers, self()}).

-spec get_response(h2_stream_set:stream_set(), stream_id()) ->
                          {ok, {hpack:headers(), iodata(), iodata()}}
                           | not_ready.
get_response(Streams, StreamId) ->
    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        closed ->
            {_, _NewStreams0} =
            h2_stream_set:close(
              Stream,
              garbage,
              Streams),
            {ok, h2_stream_set:response(Stream)};
        active ->
            not_ready
    end.

-spec get_streams(pid()) -> h2_stream_set:stream_set().
get_streams(Pid) ->
    gen_statem:call(Pid, streams).

-spec send_window_update(pid(), non_neg_integer()) -> ok.
send_window_update(Pid, Size) ->
    gen_statem:cast(Pid, {send_window_update, Size}).

-spec update_settings(pid(), h2_frame_settings:payload()) -> ok.
update_settings(Pid, Payload) ->
    gen_statem:cast(Pid, {update_settings, Payload}).

-spec stop(h2_stream_set:stream_set()) -> ok.
stop(Streams) ->
    Pid = h2_stream_set:connection(Streams),
    gen_statem:cast(Pid, stop).

%% The listen state only exists to wait around for new prim_inet
%% connections
listen(info, {inet_async, ListenSocket, Ref, {ok, ClientSocket}},
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
            {ok, AcceptSocket} = ?ssl_accept(ClientSocket, SSLOptions),
            {ok, <<"h2">>} = ssl:negotiated_protocol(AcceptSocket),
            AcceptSocket
    end,
    start_http2_server(
      Http2Settings,
      #connection{
        streams = h2_stream_set:new(server, {Transport, Socket}, undefined, []),
         socket={Transport, Socket}
        });
listen(timeout, _, State) ->
    go_away(timeout, ?PROTOCOL_ERROR, <<"listen timeout">>, State);
listen(Type, Msg, State) ->
    handle_event(Type, Msg, State).

-spec handshake(gen_statem:event_type(), {frame, h2_frame:frame()} | term(), connection()) ->
                    {next_state,
                     handshake|connected|closing,
                     connection()}.
handshake(timeout, _, State) ->
    go_away(timeout, ?PROTOCOL_ERROR, <<"handshake timeout">>, State);
handshake(Event, {frame, {FH, _Payload}=Frame}, State=#connection{streams=Streams}) ->
    %% The first frame should be the client settings as per
    %% RFC-7540#3.5
    case FH#frame_header.type of
        ?SETTINGS ->
            %% take an exclusive lock since we know this is a settings frame
            h2_stream_set:take_exclusive_lock(Streams, [settings],
                                              fun () ->
                                                      {SelfSettings, PeerSettings} = h2_stream_set:get_settings(Streams),
                                                      route_frame(Event, Frame, SelfSettings, PeerSettings, State) end);
        _ ->
            go_away(Event, ?PROTOCOL_ERROR, <<"handshake frame not SETTINGS">>, State)
    end;
handshake(Type, Msg, State) ->
    handle_event(Type, Msg, State).

connected(Event, {frame, Frame},
          #connection{streams=Streams}=Conn
         ) ->

    h2_stream_set:take_lock(Streams, [settings],
                            fun() ->
                                    {SelfSettings, PeerSettings} = h2_stream_set:get_settings(Streams),
                                    route_frame(Event, Frame, SelfSettings, PeerSettings, Conn)
                            end);
connected(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state
%continuation(Event, {frame,
 %             {#frame_header{
 %                stream_id=StreamId,
 %                 type=?CONTINUATION
 %                }, _}=Frame},
 %            #connection{
 %               continuation = #continuation_state{
 %                                 stream_id = StreamId
 %                                }
 %              }=Conn) ->
 %   route_frame(Event, Frame, Conn);
continuation(Event, {frame, _}, Conn) ->
    %% got a frame that's not part of the continuation
    go_away(Event, ?PROTOCOL_ERROR, <<"continuation violated, server">>, Conn);
continuation(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.
closing(_, _Message,
        #connection{
           socket=Socket
          }=Conn) ->
    sock:close(Socket),
    {stop, normal, Conn};
closing(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% route_frame's job needs to be "now that we've read a frame off the
%% wire, do connection based things to it and/or forward it to the
%% http2 stream processor (h2_stream:recv_frame)
-spec route_frame(
        gen_statem:event_type(),
        h2_frame:frame() | {error, term()},
        SelfSettings :: settings(),
        PeerSettings :: settings(),
        connection()) ->
    {next_state,
     connected | continuation | closing ,
     connection()}.
%% Bad Length of frame, exceedes maximum allowed size
route_frame(Event, {#frame_header{length=L}, _},
            #settings{max_frame_size=MFS},
            _PeerSettings,
            Conn)
    when L > MFS ->
    go_away(Event, ?FRAME_SIZE_ERROR, Conn);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Connection Level Frames
%%
%% Here we'll handle anything that belongs on stream 0.

%% SETTINGS, finally something that's ok on stream 0
%% This is the non-ACK case, where settings have actually arrived
route_frame(Event, {H, Payload},
            _SelfSettings,
            PS=#settings{
                  initial_window_size=OldIWS,
                  header_table_size=HTS
                 },
            #connection{
               streams=Streams
              }=Conn)
    when H#frame_header.type == ?SETTINGS,
         ?NOT_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    %% Need a way of processing settings so I know which ones came in
    %% on this one payload.
    case h2_frame_settings:validate(Payload) of
        ok ->
            {settings, PList} = Payload,

            Delta =
                case proplists:get_value(?SETTINGS_INITIAL_WINDOW_SIZE, PList) of
                    undefined ->
                        0;
                    NewIWS ->
                        NewIWS - OldIWS
                end,
            NewPeerSettings = h2_frame_settings:overlay(PS, Payload),
            %% We've just got connection settings from a peer. He have a
            %% couple of jobs to do here w.r.t. flow control

            Locks = [ encoder || proplists:get_value(?SETTINGS_HEADER_TABLE_SIZE, PList) /= undefined ] ++
                    [ streams || proplists:get_value(?SETTINGS_MAX_CONCURRENT_STREAMS, PList) /= undefined orelse Delta /= 0 ] ++
                    [ settings],

            h2_stream_set:take_exclusive_lock(Streams, Locks,
                                              fun() ->
                                                      h2_stream_set:update_peer_settings(Streams, NewPeerSettings),
                                                      EncodeContext = h2_stream_set:get_encode_context(Streams),
                                                      NewEncodeContext = hpack:new_max_table_size(HTS, EncodeContext),
                                                      h2_stream_set:update_encode_context(Streams, NewEncodeContext),
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


                                                      socksend(Conn, h2_frame_settings:ack()),
                                                      maybe_reply(Event, {next_state, connected, Conn#connection{
                                                                                                   %% Why aren't we updating send_window_size here? Section 6.9.2 of
                                                                                                   %% the spec says: "The connection flow-control window can only be
                                                                                                   %% changed using WINDOW_UPDATE frames.",
                                                                                                   streams=UpdatedStreams2
                                                                                                  }}, ok)
                                              end);
        {error, Code} ->
            go_away(Event, Code, <<"invalid frame settings">>, Conn)
    end;

%% This is the case where we got an ACK, so dequeue settings we're
%% waiting to apply
route_frame(Event, {H, _Payload},
            #settings{
               initial_window_size=OldIWS
              },
            _PeerSettings,
            Conn=#connection{
               settings_sent=SS,
               streams=Streams})
    when H#frame_header.type == ?SETTINGS,
         ?IS_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    case queue:out(SS) of
        {{value, {_Ref, NewSettings}}, NewSS} ->

            %% we have to change a bunch of stuff, so wait until we
            %% have the lock to do so
            h2_stream_set:take_exclusive_lock(Streams, [settings],
                                              fun() ->
                                                      h2_stream_set:update_self_settings(Streams, NewSettings),
            UpdatedStreams1 =
                case NewSettings#settings.initial_window_size of
                    undefined ->
                        ok;
                    NewIWS ->
                        Delta = NewIWS - OldIWS,
                        case Delta > 0 of
                            true -> send_window_update(self(), Delta);
                            false -> ok
                        end,
                        h2_stream_set:update_all_recv_windows(Delta, Streams)
                end,

            UpdatedStreams2 =
                case NewSettings#settings.max_concurrent_streams of
                    undefined ->
                        UpdatedStreams1;
                    NewMax ->
                        h2_stream_set:update_their_max_active(NewMax, UpdatedStreams1)
                end,
            maybe_reply(Event, {next_state,
             connected,
             Conn#connection{
               streams=UpdatedStreams2,
               settings_sent=NewSS
               %% Same thing here, section 6.9.2
              }}, ok)
                                                              end);
        _X ->
            maybe_reply(Event, {next_state, closing, Conn}, ok)
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stream level frames
%%


route_frame(Event, {#frame_header{type=?HEADERS}=FH, _Payload},
            _SelfSettings,
            _PeerSettings,
            #connection{}=Conn)
  when Conn#connection.type == server,
       FH#frame_header.stream_id rem 2 == 0 ->
    go_away(Event, ?PROTOCOL_ERROR, <<"HEADERS for even stream id">>, Conn);

route_frame(Event, {H, _Payload},
            _SelfSettings,
            _PeerSettings,
            #connection{}=Conn)
    when H#frame_header.type == ?PRIORITY,
         H#frame_header.stream_id == 0 ->
    go_away(Event, ?PROTOCOL_ERROR, <<"priority set on stream 0">>, Conn);
route_frame(Event, {H, _Payload},
            _SelfSettings,
            _PeerSettings,
            #connection{} = Conn)
    when H#frame_header.type == ?PRIORITY ->
    maybe_reply(Event, {next_state, connected, Conn}, ok);

route_frame(
  Event,
  {#frame_header{
      stream_id=StreamId,
      type=?RST_STREAM
      },
   _Payload},
  _SelfSettings,
  _PeerSettings,
  #connection{} = Conn) ->
    %% TODO: anything with this?
    %% EC = h2_frame_rst_stream:error_code(Payload),
    Streams = Conn#connection.streams,
    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        idle ->
            go_away(Event, ?PROTOCOL_ERROR, <<"RST on idle stream">>, Conn);
        _Stream ->
            %% TODO: RST_STREAM support
            maybe_reply(Event, {next_state, connected, Conn}, ok)
    end;
route_frame(Event, {H=#frame_header{}, _P},
            _SelfSettings,
            _PeerSettings,
            #connection{} =Conn)
    when H#frame_header.type == ?PUSH_PROMISE,
         Conn#connection.type == server ->
    go_away(Event, ?PROTOCOL_ERROR, <<"push promise sent to server">>, Conn);

%% PING
%% If not stream 0, then connection error
route_frame(Event, {H, _Payload},
            _SelfSettings,
            _PeerSettings,
            #connection{} = Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.stream_id =/= 0 ->
    go_away(Event, ?PROTOCOL_ERROR, <<"ping on stream /= 0">>, Conn);
%% If length != 8, FRAME_SIZE_ERROR
%% TODO: I think this case is already covered in h2_frame now
route_frame(Event, {H, _Payload},
            _SelfSettings,
            _PeerSettings,
           #connection{}=Conn)
    when H#frame_header.type == ?PING,
         H#frame_header.length =/= 8 ->
    go_away(Event, ?FRAME_SIZE_ERROR, Conn);
%% If PING && !ACK, must ACK
route_frame(Event, {H, Ping},
            _SelfSettings,
            _PeerSettings,
            #connection{}=Conn)
    when H#frame_header.type == ?PING,
         ?NOT_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    Ack = h2_frame_ping:ack(Ping),
    socksend(Conn, h2_frame:to_binary(Ack)),
    maybe_reply(Event, {next_state, connected, Conn}, ok);
route_frame(Event, {H, Payload},
            _SelfSettings,
            _PeerSettings,
            #connection{pings = Pings}=Conn)
    when H#frame_header.type == ?PING,
         ?IS_FLAG((H#frame_header.flags), ?FLAG_ACK) ->
    case maps:get(h2_frame_ping:to_binary(Payload), Pings, undefined) of
        undefined ->
            ok;
        {NotifyPid, _} ->
            NotifyPid ! {'PONG', self()}
    end,
    NextPings = maps:remove(Payload, Pings),
    maybe_reply(Event, {next_state, connected, Conn#connection{pings = NextPings}}, ok);
route_frame(Event, {H=#frame_header{stream_id=0}, _Payload},
            _SelfSettings,
            _PeerSettings,
            #connection{}=Conn)
    when H#frame_header.type == ?GOAWAY ->
    go_away(Event, ?NO_ERROR, Conn);

%% Window Update
route_frame(Event,
  {#frame_header{
      stream_id=0,
      type=?WINDOW_UPDATE
     },
   Payload},
  _SelfSettings,
  _PeerSettings,
  #connection{
     streams=Streams
    }=Conn) ->
    WSI = h2_frame_window_update:size_increment(Payload),
    NewSendWindow = h2_stream_set:increment_socket_send_window(WSI, Streams),
    case NewSendWindow > 2147483647 of
        true ->
            go_away(Event, ?FLOW_CONTROL_ERROR, Conn);
        false ->
            %% TODO: Priority Sort! Right now, it's just sorting on
            %% lowest stream_id first
            %Streams = h2_stream_set:sort(Conn#connection.streams),

                h2_stream_set:send_all_we_can(
                  Streams
                 ),
            maybe_reply(Event, {next_state, connected,
             Conn}, ok)
    end;
route_frame(Event,
  {#frame_header{type=?WINDOW_UPDATE}=FH,
   Payload},
  _SelfSettings,
  _PeerSettings,
  #connection{}=Conn
 ) ->
    StreamId = FH#frame_header.stream_id,
    Streams = Conn#connection.streams,
    WSI = h2_frame_window_update:size_increment(Payload),
    Stream0 = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream0) of
        idle ->
            go_away(Event, ?PROTOCOL_ERROR, list_to_binary(io_lib:format("window update on idle stream ~p", [StreamId])), Conn);
        closed ->
            rst_stream_(Event, Stream0, ?STREAM_CLOSED, Conn);
        active ->
            NewSSWS = h2_stream_set:send_window_size(Stream0)+WSI,

            case NewSSWS > 2147483647 of
                true ->
                    rst_stream_(Event, Stream0, ?FLOW_CONTROL_ERROR, Conn);
                false ->
                        h2_stream_set:send_what_we_can(
                            StreamId,
                            fun(Stream) ->
                                    h2_stream_set:increment_send_window_size(WSI, Stream)
                            end, Streams),
                    maybe_reply(Event, {next_state, connected,
                     Conn}, ok)
            end
    end;
route_frame(Event, {#frame_header{type=T}, _}, _SelfSettings, _PeerSettings, Conn)
  when T > ?CONTINUATION ->
    maybe_reply(Event, {next_state, connected, Conn}, ok);
route_frame(Event, Frame, _SelfSettings, _PeerSettings, #connection{}=Conn) ->
    error_logger:error_msg("Frame condition not covered by pattern match."
                           "Please open a github issue with this output: ~s",
                           [h2_frame:format(Frame)]),
    F = iolist_to_binary(io_lib:format("~p", [Frame])),
    go_away(Event, ?PROTOCOL_ERROR, <<"unhandled frame ", F/binary>>, Conn).

handle_event(_, {stream_finished,
              StreamId,
              Headers,
              Body,
              Trailers},
             Conn) ->
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    case h2_stream_set:type(Stream) of
        active ->
            NotifyPid = h2_stream_set:notify_pid(Stream),
            Response =
                case {Conn#connection.type, Conn#connection.garbage_on_end} of
                    {server, _} -> garbage;
                    {client, false} -> {Headers, Body, Trailers};
                    {client, true} -> garbage
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
            {keep_state, NewConn};
        _ ->
            %% stream finished multiple times
            {keep_state, Conn}
    end;
handle_event(_, {send_window_update, 0}, Conn) ->
    {keep_state, Conn};
handle_event(_, {send_window_update, Size},
             #connection{
                socket=Socket
                }=Conn) ->
    h2_frame_window_update:send(Socket, Size, 0),
    h2_stream_set:increment_socket_recv_window(Size, Conn#connection.streams),
    {keep_state, Conn};
handle_event(_, {update_settings, Http2Settings},
             #connection{}=Conn) ->
    {keep_state,
     send_settings(Http2Settings, Conn)};
handle_event(_, {send_headers, StreamId, Headers, Opts}, Conn) ->
    send_headers_(StreamId, Headers, Opts, Conn#connection.streams),
    {keep_state, Conn};
handle_event(_, {actually_send_trailers, StreamId, Trailers}, Conn=#connection{streams=Streams,
                                                                               socket=Socket}) ->

    EncodeContext0 = h2_stream_set:get_encode_context(Streams),
    Locks = case hpack:all_fields_indexed(Trailers, EncodeContext0) of
                true ->
                    [socket];
                false ->
                    [socket, encoder]
            end,
    h2_stream_set:take_exclusive_lock(Streams, Locks,
                                      fun() ->
                                              Stream = h2_stream_set:get(StreamId, Streams),
                                              EncodeContext = h2_stream_set:get_encode_context(Streams),
                                              {_SelfSettings, PeerSettings} = h2_stream_set:get_settings(Streams),
                                              {FramesToSend, NewContext} =
                                              h2_frame_headers:to_frames(h2_stream_set:stream_id(Stream),
                                                                         Trailers,
                                                                         EncodeContext,
                                                                         PeerSettings#settings.max_frame_size,
                                                                         true
                                                                        ),
                                              case Locks of
                                                  [] ->
                                                      ok;
                                                  _ ->
                                                      h2_stream_set:update_encode_context(Streams, NewContext)
                                              end,

                                              sock:send(Socket, [h2_frame:to_binary(Frame) || Frame <- FramesToSend]),
                                              {keep_state, Conn}
                                      end);
handle_event(Event, {rst_stream, StreamId, ErrorCode},
             #connection{
                streams = Streams,
                socket = _Socket
               }=Conn
            ) ->
    Stream = h2_stream_set:get(StreamId, Streams),
    rst_stream_(Event, Stream, ErrorCode, Conn);
handle_event(_, {send_trailers, StreamId, Headers, Opts},
             #connection{
                streams = Streams,
                socket = _Socket
               }=Conn
            ) ->
    BodyComplete = proplists:get_value(send_end_stream, Opts, true),

    Stream0 = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream0) of
        active ->
            h2_stream_set:send_what_we_can(
              StreamId,
              fun(Stream) -> 
                      NewS = h2_stream_set:update_trailers(Headers, Stream),
                      h2_stream_set:update_data_queue(h2_stream_set:queued_data(Stream), BodyComplete, NewS)
              end, Streams),
            send_t(Stream0, Headers),

            {keep_state,
             Conn};
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            {keep_state, Conn};
        closed ->
            {keep_state, Conn}
    end;
handle_event(_, {send_body, StreamId, Body, Opts},
             #connection{streams=Streams}=Conn) ->
    send_body_(StreamId, Body, Opts, Streams),
    {keep_state, Conn};
handle_event(_, {send_request, NotifyPid, Headers, Body},
        #connection{
            streams=Streams
        }=Conn) ->
    case send_request_(NotifyPid, Conn, Streams, Headers, Body) of
        {ok, NewConn} ->
            {keep_state, NewConn};
        {error, _Code} ->
            {keep_state, Conn}
    end;
handle_event(Event, {check_settings_ack, {Ref, NewSettings}},
             #connection{
                settings_sent=SS
               }=Conn) ->
    case queue:out(SS) of
        {{value, {Ref, NewSettings}}, _} ->
            %% This is still here!
            go_away(Event, ?SETTINGS_TIMEOUT, Conn);
        _ ->
            %% YAY!
            {keep_state, Conn}
    end;
handle_event(_, {send_bin, Binary},
             #connection{} = Conn) ->
    socksend(Conn, Binary),
    {keep_state, Conn};
handle_event(_, {send_frame, Frame},
             #connection{} =Conn) ->
    Binary = h2_frame:to_binary(Frame),
    socksend(Conn, Binary),
    {keep_state, Conn};
handle_event(stop, _StateName,
            #connection{}=Conn) ->
    go_away(stop, 0, Conn);
handle_event({call, From}, streams,
                  #connection{
                     streams=Streams
                    }=Conn) ->
    {keep_state, Conn, [{reply, From, Streams}]};
handle_event({call, From}, {get_response, StreamId},
                  #connection{}=Conn) ->
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    {Reply, NewStreams} =
        case h2_stream_set:type(Stream) of
            closed ->
                {_, NewStreams0} =
                    h2_stream_set:close(
                      Stream,
                      garbage,
                      Conn#connection.streams),
                {{ok, h2_stream_set:response(Stream)}, NewStreams0};
            active ->
                {not_ready, Conn#connection.streams}
        end,
    {keep_state, Conn#connection{streams=NewStreams}, [{reply, From, Reply}]};
handle_event({call, From}, {new_stream, CallbackMod, CallbackState, Headers, Opts, NotifyPid}, Conn) ->
    new_stream_(From, CallbackMod, CallbackState, Headers, Opts, NotifyPid, Conn);
handle_event({call, From}, {new_stream, CallbackMod, CallbackState, Headers, Body, Opts, NotifyPid}, Conn) ->
    new_stream_(From, CallbackMod, CallbackState, Headers, Body, Opts, NotifyPid, Conn);
handle_event({call, From}, {send_promise, StreamId, Headers, NotifyPid}, Conn) ->
    send_promise_(From, StreamId, Headers, NotifyPid, Conn);
handle_event({call, From}, is_push,
                  #connection{
                     streams=Streams
                    }=Conn) ->
    {_SelfSettings, #settings{enable_push=Push}} = h2_stream_set:get_settings(Streams),
    IsPush = case Push of
        1 -> true;
        _ -> false
    end,
    {keep_state, Conn, [{reply, From, IsPush}]};
handle_event({call, From}, get_peer,
                  #connection{
                     socket=Socket
                    }=Conn) ->
    case sock:peername(Socket) of
        {error, _}=Error ->
            {keep_state, Conn, [{reply, From, Error}]};
        {ok, _AddrPort}=OK ->
            {keep_state, Conn, [{reply, From, OK}]}
    end;
handle_event({call, From}, get_peercert,
                  #connection{
                     socket=Socket
                    }=Conn) ->
    case sock:peercert(Socket) of
        {error, _}=Error ->
            {keep_state, Conn, [{reply, From, Error}]};
        {ok, _Cert}=OK ->
            {keep_state, Conn, [{reply, From, OK}]}
    end;
handle_event({call, From}, {send_request, NotifyPid, Headers, Body},
        #connection{
            streams=Streams
        }=Conn) ->
    case send_request_(NotifyPid, Conn, Streams, Headers, Body) of
        {ok, NewConn} ->
            {keep_state, NewConn, [{reply, From, ok}]};
        {error, Code} ->
            {keep_state, Conn, [{reply, From, {error, Code}}]}
    end;
handle_event({call, From}, {send_request, NotifyPid, Headers, Body, CallbackMod, CallbackOpts},
        #connection{
            streams=Streams
        }=Conn) ->
    case send_request_(NotifyPid, Conn, Streams, Headers, Body, CallbackMod, CallbackOpts) of
        {ok, NewConn} ->
            {keep_state, NewConn, [{reply, From, ok}]};
        {error, Code} ->
            {keep_state, Conn, [{reply, From, {error, Code}}]}
    end;
handle_event({call, From}, {send_ping, NotifyPid},
             #connection{pings = Pings} = Conn) ->
    PingValue = crypto:strong_rand_bytes(8),
    Frame = h2_frame_ping:new(PingValue),
    Headers = #frame_header{stream_id = 0, flags = 16#0},
    Binary = h2_frame:to_binary({Headers, Frame}),

    case socksend(Conn, Binary) of
        ok ->
            NextPings = maps:put(PingValue, {NotifyPid, erlang:monotonic_time(milli_seconds)}, Pings),
            NextConn = Conn#connection{pings = NextPings},
            {keep_state, NextConn, [{reply, From, ok}]};
        {error, _Reason} = Err ->
            {keep_state, Conn, [{reply, From, Err}]}
    end;

%% Socket Messages
%% {tcp_passive, Socket}
handle_event(info, {tcp_passive, Socket},
            #connection{
               socket={gen_tcp, Socket}
              }=Conn) ->
    handle_socket_passive(Conn);
%% {tcp_closed, Socket}
handle_event(info, {tcp_closed, Socket},
            #connection{
              socket={gen_tcp, Socket}
             }=Conn) ->
    handle_socket_closed(Conn);
%% {ssl_closed, Socket}
handle_event(info, {ssl_closed, Socket},
            #connection{
               socket={ssl, Socket}
              }=Conn) ->
    handle_socket_closed(Conn);
%% {tcp_error, Socket, Reason}
handle_event(info, {tcp_error, Socket, Reason},
            #connection{
               socket={gen_tcp,Socket}
              }=Conn) ->
    handle_socket_error(Reason, Conn);
%% {ssl_error, Socket, Reason}
handle_event(info, {ssl_error, Socket, Reason},
            #connection{
               socket={ssl,Socket}
              }=Conn) ->
    handle_socket_error(Reason, Conn);
handle_event(info, {go_away, ErrorCode}, Conn) ->
    gen_statem:cast(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    {next_state, closing, Conn};
%handle_event(info, {_,R},
%           #connection{}=Conn) ->
%    handle_socket_error(R, Conn);
handle_event(Event, Msg, Conn) ->
    error_logger:error_msg("h2_connection received unexpected event of type ~p : ~p", [Event, Msg]),
    %%go_away(Event, ?PROTOCOL_ERROR, Conn).
    {keep_state, Conn}.

code_change(_OldVsn, StateName, Conn, _Extra) ->
    {ok, StateName, Conn}.

terminate(normal, _StateName, _Conn) ->
    ok;
terminate(_Reason, _StateName, _Conn=#connection{}) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    ok.

new_stream_(From, CallbackMod, CallbackState, Headers, Opts, NotifyPid, Conn=#connection{streams=Streams}) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              next,
              NotifyPid,
              CallbackMod,
              CallbackState,
              Streams)
        of
            {error, Code, _NewStream} ->
                %% TODO: probably want to have events like this available for metrics
                %% tried to create new_stream but there are too many
                {{error, Code}, Streams};
            {Pid, NextId, GoodStreamSet} ->
                {{NextId, Pid}, GoodStreamSet}
        end,

    Conn1 = Conn#connection{
              streams=NewStreams
             },
    Conn2 = case Reply of
                {error, _Code} ->
                    Conn1;
                {NextId0, _Pid} ->
                    send_headers_(NextId0, Headers, Opts, NewStreams),
                    Conn1
            end,
    {keep_state, Conn2, [{reply, From, Reply}]}.

new_stream_(From, CallbackMod, CallbackState, Headers, Body, Opts, NotifyPid, Conn=#connection{streams=Streams}) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              next,
              NotifyPid,
              CallbackMod,
              CallbackState,
              Streams)
        of
            {error, Code, _NewStream} ->
                %% TODO: probably want to have events like this available for metrics
                %% tried to create new_stream but there are too many
                {{error, Code}, Streams};
            {Pid, NextId, GoodStreamSet} ->
                {{NextId, Pid}, GoodStreamSet}
        end,

    Conn1 = Conn#connection{
              streams=NewStreams
             },
    Conn2 = case Reply of
                {error, _Code} ->
                    Conn1;
                {NextId0, _Pid} ->
                    send_headers_(NextId0, Headers, Opts, Streams),
                    send_body_(NextId0, Body, Opts, Streams),
                    Conn1
            end,
    {keep_state, Conn2, [{reply, From, Reply}]}.

send_headers_(StreamId, Headers, Opts, Streams) ->
    StreamComplete = proplists:get_value(send_end_stream, Opts, false),
    Socket = h2_stream_set:socket(Streams),

    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        active ->
            EncodeContext0 = h2_stream_set:get_encode_context(Streams),
            Locks = case hpack:all_fields_indexed(Headers, EncodeContext0) of
                        true ->
                            [];
                        false ->
                            [encoder]
                    end,
            h2_stream_set:take_exclusive_lock(Streams, Locks,
                                              fun() ->
                                                      {_SelfSettings, PeerSettings} = h2_stream_set:get_settings(Streams),
                                                      EncodeContext = h2_stream_set:get_encode_context(Streams),
                                                      {FramesToSend, NewContext} =
                                                      h2_frame_headers:to_frames(h2_stream_set:stream_id(Stream),
                                                                                 Headers,
                                                                                 EncodeContext,
                                                                                 PeerSettings#settings.max_frame_size,
                                                                                 StreamComplete
                                                                                ),
                                                      case Locks of
                                                          [] ->
                                                              ok;
                                                          _ ->
                                                              h2_stream_set:update_encode_context(Streams, NewContext)
                                                      end,
                                                      sock:send(Socket, [h2_frame:to_binary(Frame) || Frame <- FramesToSend]),
                                                      send_h(Stream, Headers),
                                                      ok
                                              end);
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            ok;
        closed ->
            ok
    end.

send_promise_(From, StreamId, Headers, NotifyPid, Conn=#connection{streams=Streams}) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              next,
              NotifyPid,
              undefined,
              [],
              Streams)
        of
            {error, Code, _NewStream} ->
                %% TODO: probably want to have events like this available for metrics
                %% tried to create new_stream but there are too many
                {{error, Code}, Streams};
            {Pid, NextId, GoodStreamSet} ->
                {{NextId, Pid}, GoodStreamSet}
        end,

    Conn1 = Conn#connection{
              streams=NewStreams
             },
    Conn2 = case Reply of
                {error, _Code} ->
                    Conn1;
                {NextId0, _Pid} ->
                    EncodeContext0 = h2_stream_set:get_encode_context(Streams),
                    Locks = case hpack:all_fields_indexed(Headers, EncodeContext0) of
                                true ->
                                    [];
                                false ->
                                    [encoder]
                            end,
                    h2_stream_set:take_exclusive_lock(Streams, Locks,
                                                      fun() ->
                                                              OldContext = h2_stream_set:get_encode_context(Streams),
                                                              %% TODO: This could be a series of frames, not just one
                                                              {PromiseFrame, NewContext} =
                                                              h2_frame_push_promise:to_frame(
                                                                StreamId,
                                                                NextId0,
                                                                Headers,
                                                                OldContext
                                                               ),

                                                              %% Send the PP Frame
                                                              Binary = h2_frame:to_binary(PromiseFrame),
                                                              sock:send(h2_stream_set:socket(Streams), Binary),

                                                              case Locks of
                                                                  [] ->
                                                                      ok;
                                                                  _ ->
                                                                      h2_stream_set:update_encode_context(Streams, NewContext)
                                                              end,

                                                              %% Get the promised stream rolling
                                                              h2_stream:send_pp(_Pid, Headers),

                                                              ok
                                                      end),
                    Conn1
            end,
    {keep_state, Conn2, [{reply, From, Reply}]}.


send_trailers_(StreamId, Trailers, Opts, Streams) ->
    BodyComplete = proplists:get_value(send_end_stream, Opts, true),

    Stream0 = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream0) of
        active ->
                h2_stream_set:send_what_we_can(
                  StreamId,
                  fun(Stream) ->
                          NewS = h2_stream_set:update_trailers(Trailers, Stream),
                          h2_stream_set:update_data_queue(h2_stream_set:queued_data(Stream), BodyComplete, NewS)
                  end, Streams),

            send_t(Stream0, Trailers),
            ok;
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            ok;
        closed ->
            ok
    end.


go_away(Event, ErrorCode, Conn) ->
    go_away(Event, ErrorCode, <<>>, Conn).

go_away(Event, ErrorCode, Reason, Conn) ->
    go_away_(ErrorCode, Reason, Conn#connection.socket, Conn#connection.streams),
    %% TODO: why is this sending a string?
    gen_statem:cast(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    maybe_reply(Event, {next_state, closing, Conn}, ok).


-spec go_away_(error_code(), sock:socket(), h2_stream_set:stream_set()) -> ok.
go_away_(ErrorCode, Socket, Streams) ->
    go_away_(ErrorCode, <<>>, Socket, Streams).

go_away_(ErrorCode, Reason, Socket, Streams) ->
    NAS = h2_stream_set:get_next_available_stream_id(Streams),
    GoAway = h2_frame_goaway:new(NAS, ErrorCode, Reason),
    GoAwayBin = h2_frame:to_binary({#frame_header{
                                       stream_id=0
                                      }, GoAway}),
    h2_stream_set:take_exclusive_lock(Streams, [socket], fun() ->
                                                                 sock:send(Socket, GoAwayBin)
                                                         end),
    ok.

maybe_reply({call, From}, {next_state, NewState, NewData}, Msg) ->
    {next_state, NewState, NewData, [{reply, From, Msg}]};
maybe_reply(_, Return, _) ->
    Return.

%% rst_stream_/3 looks for a running process for the stream. If it
%% finds one, it delegates sending the rst_stream frame to it, but if
%% it doesn't, it seems like a waste to spawn one just to kill it
%% after sending that frame, so we send it from here.
-spec rst_stream_(
        gen_statem:event_type(),
        h2_stream_set:stream(),
        error_code(),
        connection()
       ) -> {next_state, connected, connection()}.
rst_stream_(Event, Stream, ErrorCode, Conn) ->
    rst_stream__(Stream, ErrorCode, Conn#connection.socket),
    maybe_reply(Event, {next_state, connected, Conn}, ok).

-spec rst_stream__(
        h2_stream_set:stream(),
        error_code(),
        sock:sock()
       ) -> ok.
rst_stream__(Stream, ErrorCode, Sock) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% Can this ever be undefined?
            Pid = h2_stream_set:stream_pid(Stream),
            %% h2_stream's rst_stream will take care of letting us know
            %% this stream is closed and will send us a message to close the
            %% stream somewhere else
            h2_stream:rst_stream(Pid, ErrorCode);
        _ ->
            StreamId = h2_stream_set:stream_id(Stream),
            RstStream = h2_frame_rst_stream:new(ErrorCode),
            RstStreamBin = h2_frame:to_binary(
                          {#frame_header{
                              stream_id=StreamId
                             },
                           RstStream}),
            sock:send(Sock, RstStreamBin)
    end.

-spec send_settings(settings(), connection()) -> connection().
send_settings(SettingsToSend,
              #connection{
                 streams=Streams,
                 settings_sent=SS
                }=Conn) ->
    Ref = make_ref(),
    {CurrentSettings, _PeerSettings} = h2_stream_set:get_settings(Streams),
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
                  timer:sleep(5000),
                  gen_statem:cast(Self, {check_settings_ack,SS})
              end,
    spawn_link(SendAck).

%% private socket handling

spawn_data_receiver(Socket, Streams, Flow) ->
    Connection = self(),
    h2_stream_set:set_socket_recv_window_size(?DEFAULT_INITIAL_WINDOW_SIZE, Streams),
    h2_stream_set:set_socket_send_window_size(?DEFAULT_INITIAL_WINDOW_SIZE, Streams),
    Type = h2_stream_set:stream_set_type(Streams),
    {CallbackMod, CallbackOpts} = h2_stream_set:get_callback(Streams),
    spawn_link(fun() ->
                       fun F(S, St, First, Decoder) ->
                               case h2_frame:read(S, infinity) of
                                   {error, closed} ->
                                       Connection ! socket_closed(S);
                                   {error, Reason} ->
                                       Connection ! socket_error(S, Reason);
                                   {stream_error, 0, Code} ->
                                       %% Remaining Bytes don't matter, we're closing up shop.
                                       go_away_(Code, <<"stream error">>, S, St),
                                       Connection ! {go_away, Code};
                                   {stream_error, StreamId, Code} ->
                                       Stream = h2_stream_set:get(StreamId, St),
                                       rst_stream__(Stream, Code, S),
                                       F(S, St, false, Decoder);
                                   {#frame_header{length=L} = Header, Payload} = Frame ->
                                       %% TODO move some of the cases of route_frame into here
                                       %% so we can send frames directly to the stream pids
                                       StreamId = Header#frame_header.stream_id,
                                       {#settings{max_frame_size=MFS}, _} = h2_stream_set:get_settings(St),
                                       case Header#frame_header.type of
                                           _ when L > MFS andalso false ->
                                               go_away_(?FRAME_SIZE_ERROR, list_to_binary(io_lib:format("received frame of size ~p over max of ~p", [L, MFS])), S, St),
                                               Connection ! {go_away, ?FRAME_SIZE_ERROR};
                                           %% The first frame should be the client settings as per
                                           %% RFC-7540#3.5
                                           HType when HType /= ?SETTINGS andalso First ->
                                               go_away_(?PROTOCOL_ERROR, <<"non settings frame sent first">>, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?DATA ->
                                               L = Header#frame_header.length,
                                               case L > h2_stream_set:socket_recv_window_size(St) of
                                                   true ->
                                                       go_away_(?FLOW_CONTROL_ERROR, S, St),
                                                       Connection ! {go_away, ?FLOW_CONTROL_ERROR};
                                                   false ->
                                                       Stream = h2_stream_set:get(Header#frame_header.stream_id, Streams),

                                                       case h2_stream_set:type(Stream) of
                                                           active ->
                                                               case {
                                                                 h2_stream_set:recv_window_size(Stream) < L,
                                                                 Flow,
                                                                 L > 0
                                                                } of
                                                                   {true, _, _} ->
                                                                       rst_stream__(Stream,
                                                                                   ?FLOW_CONTROL_ERROR,
                                                                                   S);
                                                                   %% If flow control is set to auto, and L > 0, send
                                                                   %% window updates back to the peer. If L == 0, we're
                                                                   %% not allowed to send window_updates of size 0, so we
                                                                   %% hit the next clause
                                                                   {false, auto, true} ->
                                                                       %% Make window size great again
                                                                       h2_frame_window_update:send(S,
                                                                                                   L, Header#frame_header.stream_id),
                                                                       %send_window_update(Connection, L),
                                                                       h2_stream_set:decrement_socket_recv_window(L, St),
                                                                       recv_data(Stream, Frame),
                                                                       h2_frame_window_update:send(S, L, 0),
                                                                       h2_stream_set:increment_socket_recv_window(L, St),
                                                                       F(S, St, false, Decoder);
                                                                   %% Either
                                                                   %% {false, auto, true} or
                                                                   %% {false, manual, _DoesntMatter}
                                                                   _Tried ->
                                                                       recv_data(Stream, Frame),
                                                                       h2_stream_set:decrement_socket_recv_window(L, St),
                                                                       {ok, ok} = h2_stream_set:update(Header#frame_header.stream_id,
                                                                                            fun(Str) ->
                                                                                                    {h2_stream_set:decrement_recv_window(L, Str), ok}
                                                                                            end,
                                                                         Streams),
                                                                       F(S, St, false, Decoder)
                                                               end;
                                                           StreamType ->
                                                               go_away_(?PROTOCOL_ERROR, list_to_binary(io_lib:format("data on ~p stream ~p", [StreamType, Header#frame_header.stream_id])), S, St),
                                                               Connection ! {go_away, ?PROTOCOL_ERROR}
                                                       end
                                               end;
                                           ?HEADERS when Type == server, StreamId rem 2 == 0 ->
                                               go_away_(?PROTOCOL_ERROR, <<"Headers on even streamid on server">>, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?HEADERS when Type == server ->
                                               Stream0 = h2_stream_set:get(StreamId, Streams),
                                               ContinuationType =
                                               case h2_stream_set:type(Stream0) of
                                                   idle ->
                                                       case
                                                           h2_stream_set:new_stream(
                                                             StreamId,
                                                             Connection,
                                                             CallbackMod,
                                                             CallbackOpts,
                                                             Streams) of
                                                           {error, ErrorCode, NewStream} ->
                                                               rst_stream__(NewStream, ErrorCode, S),
                                                               none;
                                                           {_, _, _NewStreams} ->
                                                               headers
                                                       end;
                                                   active ->
                                                       trailers;
                                                   _ ->
                                                       headers
                                               end,
                                               case ContinuationType of
                                                   none ->
                                                       F(S, St, false, Decoder);
                                                   _ ->
                                                       Frames = case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_HEADERS) of
                                                                    true ->
                                                                        %% complete headers frame, just do it
                                                                        [Frame];
                                                                    false ->
                                                                        read_continuations(Connection, S, StreamId, St, [Frame])
                                                                end,
                                                       HeadersBin = h2_frame_headers:from_frames(Frames),
                                                       case hpack:decode(HeadersBin, Decoder) of
                                                           {error, compression_error} ->
                                                               go_away_(?COMPRESSION_ERROR, S, St),
                                                               Connection ! {go_away, ?COMPRESSION_ERROR};
                                                           {ok, {Headers, NewDecoder}} ->
                                                               Stream = h2_stream_set:get(StreamId, St),
                                                               %% always headers or trailers!
                                                               recv_h_(Stream, S, Headers),
                                                               case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_STREAM) of
                                                                   true ->
                                                                       recv_es_(Stream, S);
                                                                   false ->
                                                                       ok
                                                               end,
                                                               F(S, St, false, NewDecoder)
                                                       end
                                               end;
                                           ?HEADERS when Type == client ->
                                               Frames = case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_HEADERS) of
                                                            true ->
                                                                %% complete headers frame, just do it
                                                                [Frame];
                                                            false ->
                                                                read_continuations(Connection, S, StreamId, St, [Frame])
                                                        end,
                                               HeadersBin = h2_frame_headers:from_frames(Frames),
                                               case hpack:decode(HeadersBin, Decoder) of
                                                   {error, compression_error} ->
                                                       go_away_(?COMPRESSION_ERROR, S, St),
                                                       Connection ! {go_away, ?COMPRESSION_ERROR};
                                                   {ok, {Headers, NewDecoder}} ->
                                                       Stream = h2_stream_set:get(StreamId, St),
                                                       %% always headers or trailers!
                                                       recv_h_(Stream, S, Headers),
                                                       case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_STREAM) of
                                                           true ->
                                                               recv_es_(Stream, S);
                                                           false ->
                                                               ok
                                                       end,
                                                       F(S, St, false, NewDecoder)
                                               end;
                                           ?PRIORITY when StreamId == 0 ->
                                               go_away_(?PROTOCOL_ERROR, <<"set priority on stream 0">>, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?PRIORITY ->
                                               %% seems unimplemented?
                                               F(S, St, false, Decoder);
                                           ?RST_STREAM when StreamId == 0 ->
                                               go_away_(?PROTOCOL_ERROR, <<"RST on stream 0">>, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?RST_STREAM ->
                                               Stream = h2_stream_set:get(StreamId, St),
                                               %% TODO: anything with this?
                                               %% EC = h2_frame_rst_stream:error_code(Payload),
                                               case h2_stream_set:type(Stream) of
                                                   idle ->
                                                       go_away_(?PROTOCOL_ERROR, <<"RST on idle stream">>, S, St),
                                                       Connection ! {go_away, ?PROTOCOL_ERROR};
                                                   _Stream ->
                                                       %% TODO: RST_STREAM support
                                                       F(S, St, false, Decoder)
                                               end;
                                           ?PING when StreamId /= 0 ->
                                               go_away_(?PROTOCOL_ERROR, <<"ping on stream /= 0">>, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?PING when Header#frame_header.length /= 8 ->
                                               go_away_(?FRAME_SIZE_ERROR, <<"Header length is not 8">>, S, St),
                                               Connection ! {go_away, ?FRAME_SIZE_ERROR};
                                           ?PING when ?NOT_FLAG((Header#frame_header.flags), ?FLAG_ACK) ->
                                               Ack = h2_frame_ping:ack(Payload),
                                               h2_stream_set:take_exclusive_lock(St, [socket],
                                                                                 fun() ->
                                                                                         sock:send(S, h2_frame:to_binary(Ack))
                                                                                 end),
                                               F(S, St, false, Decoder);
                                           ?PUSH_PROMISE when Type == server ->
                                               go_away_(?PROTOCOL_ERROR, <<"push_promise sent to server">>, S, St),
                                               Connection ! {go_away, ?PROTOCOL_ERROR};
                                           ?PUSH_PROMISE when Type == client ->
                                               PSID = h2_frame_push_promise:promised_stream_id(Payload),
                                               Old = h2_stream_set:get(StreamId, Streams),
                                               NotifyPid = h2_stream_set:notify_pid(Old),
                                               h2_stream_set:new_stream(
                                                 PSID,
                                                 NotifyPid,
                                                 CallbackMod,
                                                 CallbackOpts,
                                                 Streams),

                                               Frames = case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_HEADERS) of
                                                            true ->
                                                                %% complete headers frame, just do it
                                                                [Frame];
                                                            false ->
                                                                read_continuations(Connection, S, StreamId, St, [Frame])
                                                        end,
                                               PromiseBin = h2_frame_headers:from_frames(Frames),
                                               case hpack:decode(PromiseBin, Decoder) of
                                                   {error, compression_error} ->
                                                       go_away_(?COMPRESSION_ERROR, S, St),
                                                       Connection ! {go_away, ?COMPRESSION_ERROR};
                                                   {ok, {Promise, NewDecoder}} ->

                                                       New = h2_stream_set:get(PSID, Streams),
                                                       recv_pp(New, Promise),

                                                       case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_STREAM) of
                                                           true ->
                                                               recv_es_(Old, S);
                                                           false ->
                                                               ok
                                                       end,

                                                       F(S, St, false, NewDecoder)
                                               end;

                                           %% TODO ACK'd pings
                                           %% TODO stream window updates (need to share send window size)
                                           _ ->
                                               gen_statem:call(Connection, {frame, Frame}),
                                               F(S, St, false, Decoder)
                                       end
                               end
                       end(Socket, Streams, true, hpack:new_context())
               end).

read_continuations(Connection, Socket, StreamId, Streams, Acc) ->
    case h2_frame:read(Socket, infinity) of
        {error, closed} ->
            Connection ! socket_closed(Socket),
            exit(normal);
        {error, Reason} ->
            Connection ! socket_error(Socket, Reason),
            exit(normal);
        {stream_error, _StreamId, _Code} ->
            go_away_(?PROTOCOL_ERROR, <<"continuation violated stream_error">>, Socket, Streams),
            Connection ! {go_away, ?PROTOCOL_ERROR},
            exit(normal);
        {Header, _Payload} = Frame ->
            case Header#frame_header.type == ?CONTINUATION andalso Header#frame_header.stream_id == StreamId of
                false ->
                    go_away_(?PROTOCOL_ERROR, <<"continuation violated">>, Socket, Streams),
                    Connection ! {go_away, ?PROTOCOL_ERROR},
                    exit(normal);
                true ->
                    case ?IS_FLAG((Header#frame_header.flags), ?FLAG_END_HEADERS) of
                        true ->
                            lists:reverse([Frame|Acc]);
                        false ->
                            read_continuations(Connection, Socket, StreamId, Streams, [Frame|Acc])
                    end
            end
    end.

socket_closed({gen_tcp, Socket}) ->
    {tcp_closed, Socket};
socket_closed({ssl, Socket}) ->
    {ssl_closed, Socket}.

socket_error({gen_tcp, Socket}, Reason) ->
    {tcp_error, Socket, Reason};
socket_error({ssl, Socket}, Reason) ->
    {ssl_error, Socket, Reason}.

client_options(Transport, SSLOptions, SocketOptions) ->
    DefaultSocketOptions = [
                           {mode, binary},
                           {packet, raw},
                           {active, false}
                          ],
    ClientSocketOptions = merge_options(DefaultSocketOptions, SocketOptions),
    case Transport of
        ssl ->
            [{alpn_advertised_protocols, [<<"h2">>]}|ClientSocketOptions ++ SSLOptions];
        gen_tcp ->
            ClientSocketOptions
    end.

merge_options(A, B) ->
    proplists:from_map(maps:merge(proplists:to_map(A), proplists:to_map(B))).

start_http2_server(
  Http2Settings,
  #connection{
     socket=Socket
    }=Conn) ->
    case accept_preface(Socket) of
        ok ->
            Flow = application:get_env(chatterbox, server_flow_control, auto),
            Receiver = spawn_data_receiver(Socket, Conn#connection.streams, Flow),
            NewState =
                Conn#connection{
                  type=server,
                  receiver=Receiver
                 },
            {next_state,
             handshake,
             send_settings(Http2Settings, NewState)
            };
        {error, invalid_preface} ->
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


handle_socket_passive(Conn) ->
    {keep_state, Conn}.

handle_socket_closed(Conn) ->
    {stop, normal, Conn}.

handle_socket_error(Reason, Conn) ->
    {stop, {shutdown, Reason}, Conn}.

socksend(#connection{
            socket=Socket,
            streams=Streams
           }, Data) ->
    h2_stream_set:take_exclusive_lock(Streams, [socket], fun() ->
    case sock:send(Socket, Data) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end
                                                         end).

%% Stream API: These will be moved

recv_h_(Stream,
       Sock,
       Headers) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% If the stream is active, let the process deal with it.
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, {recv_h, Headers});
        closed ->
            %% If the stream is closed, there's no running FSM
            rst_stream__(Stream, ?STREAM_CLOSED, Sock);
        idle ->
            %% If we're calling this function, we've already activated
            %% a stream FSM (probably). On the off chance we didn't,
            %% we'll throw this
            rst_stream__(Stream, ?STREAM_CLOSED, Sock)
    end.


-spec send_h(
        h2_stream_set:stream(),
        hpack:headers()) ->
                    ok.
send_h(Stream, Headers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% TODO: Should this be some kind of error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {send_h, Headers})
    end.

-spec send_t(
        h2_stream_set:stream(),
        hpack:headers()) ->
                    ok.
send_t(Stream, Trailers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% TODO:  Should this be some kind of error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {send_t, Trailers})
    end.


recv_es_(Stream, Sock) ->
    case h2_stream_set:type(Stream) of
        active ->
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, recv_es);
        closed ->
            rst_stream__(Stream, ?STREAM_CLOSED, Sock);
        idle ->
            rst_stream__(Stream, ?STREAM_CLOSED, Sock)
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
            h2_stream:send_event(Pid, {recv_pp, Headers})
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
            h2_stream:send_event(Pid, {recv_data, Frame})
    end.

send_request_(NotifyPid, Conn, Streams, Headers, Body) ->
    {CallbackMod, CallbackOpts} = h2_stream_set:get_callback(Streams),
    send_request_(NotifyPid, Conn, Streams, Headers, Body, CallbackMod, CallbackOpts).

send_request_(NotifyPid, Conn, Streams, Headers, Body, CallbackMod, CallbackOpts) ->
    case
        h2_stream_set:new_stream(
          next,
            NotifyPid,
            CallbackMod,
            CallbackOpts,
            Streams)
    of
        {error, Code, _NewStream} ->
            %% error creating new stream
            {error, Code};
        {_Pid, NextId, GoodStreamSet} ->
            send_headers_(NextId, Headers, [], GoodStreamSet),
            send_body_(NextId, Body, [], GoodStreamSet),

            {ok, Conn#connection{streams=GoodStreamSet}}
    end.

send_body_(StreamId, Body, Opts, Streams) ->
    BodyComplete = proplists:get_value(send_end_stream, Opts, true),

    Stream0 = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream0) of
        active ->
                h2_stream_set:send_what_we_can(
                  StreamId,
                  fun(Stream) ->
                          OldBody = h2_stream_set:queued_data(Stream),
                          NewBody = case is_binary(OldBody) of
                                        true -> <<OldBody/binary, Body/binary>>;
                                        false -> Body
                                    end,
                          h2_stream_set:update_data_queue(NewBody, BodyComplete, Stream)
                  end, Streams),

                ok;
        idle ->
            %% Sending DATA frames on an idle stream?  It's a
            %% Connection level protocol error on reciept, but If we
            %% have no active stream what can we even do?
            ok;
        closed ->
            ok
    end.

