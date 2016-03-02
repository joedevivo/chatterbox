-module(http2_connection).

-behaviour(gen_fsm).

-include("http2.hrl").
-compile(export_all). %% for now
-export([
         start_client_link/4,
         start_ssl_upgrade_link/4,
         start_server_link/2,
         become/1,
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
         get_peer/1
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

-export([handshake/2,
         connected/2,
         continuation/2,
         closing/2
        ]).

-export([
         get_stream/2,
         go_away/2
        ]).

-record(h2_listening_state, {
          ssl_options   :: [ssl:ssloption()],
          listen_socket :: ssl:sslsocket() | inet:socket(),
          transport     :: gen_tcp | ssl,
          listen_ref    :: non_neg_integer(),
          acceptor_callback = fun chatterbox_sup:start_socket/0 :: fun()
         }).

-spec start_client_link(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:ssloption()]) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link(Transport, Host, Port, SSLOptions) ->
    gen_fsm:start_link(?MODULE, {client, Transport, Host, Port, SSLOptions}, []).

-spec start_ssl_upgrade_link(inet:ip_address() | inet:hostname(),
                             inet:port_number(),
                             binary(),
                             [ssl:ssloption()]) ->
                                    {ok, pid()} | ignore | {error, term()}.
start_ssl_upgrade_link(Host, Port, InitialMessage, SSLOptions) ->
    gen_fsm:start_link(?MODULE, {client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions}, []).

-spec start_server_link(socket(),
                        [ssl:ssloption()]) ->
                               {ok, pid()} | ignore | {error, term()}.
start_server_link({Transport, ListenSocket}, SSLOptions) ->
    gen_fsm:start_link(?MODULE, {server, {Transport, ListenSocket}, SSLOptions}, []).

-spec become(socket()) -> no_return().
become({Transport, Socket}) ->
    ok = Transport:setopts(Socket, [{packet, raw}, binary]),
    {_, _, NewState} = start_http2_server(#connection_state{
                                             socket = {Transport, Socket}
                                            }),
    gen_fsm:enter_loop(?MODULE,
                       [],
                       handshake,
                       NewState).

%% Init callback
init({client, Transport, Host, Port, SSLOptions}) ->
    {ok, Socket} = Transport:connect(Host, Port, client_options(Transport, SSLOptions)),
    ok = Transport:setopts(Socket, [{packet, raw}, binary]),
    Transport:send(Socket, <<?PREFACE>>),
    InitialState = #connection_state{
                      socket = {Transport, Socket},
                      next_available_stream_id=1
                     },
    {ok,
     handshake,
     send_settings(InitialState),
     4500};
init({client_ssl_upgrade, Host, Port, InitialMessage, SSLOptions}) ->
    {ok, TCP} = gen_tcp:connect(Host, Port, [{active, false}]),
    gen_tcp:send(TCP, InitialMessage),
    {ok, Socket} = ssl:connect(TCP, client_options(ssl, SSLOptions)),

    active_once({ssl, Socket}),
    ok = ssl:setopts(Socket, [{packet, raw}, binary]),
    ssl:send(Socket, <<?PREFACE>>),
    InitialState = #connection_state{
                      socket = {ssl, Socket},
                      next_available_stream_id=1
                     },
    {ok,
     handshake,
     send_settings(InitialState),
     4500};
init({server, {Transport, ListenSocket}, SSLOptions}) ->
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
        transport = Transport
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

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).

%% The listen state only exists to wait around for new prim_inet
%% connections
listen(timeout, State) ->
    go_away(?PROTOCOL_ERROR, State).

-spec handshake(timeout|{frame, frame()}, #connection_state{}) ->
                    {next_state,
                     handshake|connected|closing,
                     #connection_state{}}.
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
          S = #connection_state{}
         ) ->
    lager:debug("[connected] {frame, ~p}", [http2_frame:format(Frame)]),
    route_frame(Frame, S).

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state


continuation({frame, {#frame_header{
                         stream_id=StreamId,
                         type=?CONTINUATION
                        }, _}=Frame},
             #connection_state{
                continuation_stream_id = StreamId
               } = State) ->
    lager:debug("[continuation] [next] ~p", [http2_frame:format(Frame)]),
    route_frame(Frame, State);
continuation(_, State) ->
    go_away(?PROTOCOL_ERROR, State).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.

closing(Message, State=#connection_state{
        socket={Transport, Socket}
    }) ->
    lager:debug("[closing] s ~p", [Message]),
    Transport:close(Socket),
    {stop, normal, State};
closing(Message, State) ->
    lager:debug("[closing] ~p", [Message]),
    {stop, normal, State}.

%% route_frame's job needs to be "now that we've read a frame off the
%% wire, do connection based things to it and/or forward it to the
%% http2 stream processor (http2_stream:recv_frame)
-spec route_frame(frame() | {error, term()}, #connection_state{}) ->
    {next_state,
     connected | continuation | closing ,
     #connection_state{}}.
%% Bad Length of frame, exceedes maximum allowed size
route_frame({#frame_header{length=L}, _},
            S = #connection_state{
                   recv_settings=#settings{max_frame_size=MFS}
                  })
    when L > MFS ->
    go_away(?FRAME_SIZE_ERROR, S);
%% Some types have fixed lengths and there's nothing we can do about
%% it except Frame Size error
route_frame({#frame_header{
                length=L,
                type=T}, _Payload},
            S)
  when (T == ?PRIORITY      andalso L =/= 5) orelse
       (T == ?RST_STREAM    andalso L =/= 4) orelse
       (T == ?PING          andalso L =/= 8) orelse
       (T == ?WINDOW_UPDATE andalso L =/= 4) ->
    lager:debug("bad frame size?"),
    go_away(?FRAME_SIZE_ERROR, S);

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
            S = #connection_state{})
  when Type == ?DATA;
       Type == ?HEADERS;
       Type == ?PRIORITY;
       Type == ?RST_STREAM;
       Type == ?PUSH_PROMISE;
       Type == ?CONTINUATION ->
    lager:error("~p frame not allowed on stream 0", [?FT(Type)]),
    go_away(?PROTOCOL_ERROR, S);

%% Only allowed on stream 0
route_frame({#frame_header{
                stream_id=StreamId,
                type=Type
                },_Payload},
            S = #connection_state{})
  when StreamId > 0 andalso (
       Type == ?SETTINGS orelse
       Type == ?PING orelse
       Type == ?GOAWAY) ->
    lager:error("~p frame only allowed on stream 0", [?FT(Type)]),
    go_away(?PROTOCOL_ERROR, S);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Connection Level Frames
%%
%% Here we'll handle anything that belongs on stream 0.


%% SETTINGS, finally something that's ok on stream 0
%% This is the non-ACK case, where settings have actually arrived
route_frame({H, Payload}, S = #connection_state{
                                 send_settings=SS=#settings{
                                                     initial_window_size=OldIWS
                                                    },
                                 streams = Streams
                                })
    when H#frame_header.type == ?SETTINGS,
         ?NOT_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received SETTINGS"),

    %% Need a way of processing settings so I know which ones came in
    %% on this one payload.
    {settings, PList} = Payload,
    Delta = case proplists:get_value(?SETTINGS_INITIAL_WINDOW_SIZE, PList) of
        undefined ->
            0;
        NewIWS ->
            OldIWS - NewIWS
    end,
    NewSendSettings = http2_frame_settings:overlay(SS, Payload),

    %% Adjust all open and half_closed_remote streams send_window_size
    %% TODO: This will probably come in handy on the client side too
    NewStreams = lists:map(fun({StreamId, Stream=#stream_state{state=open,send_window_size=SWS}}) ->
                               {StreamId, Stream#stream_state{
                                            send_window_size=SWS - Delta
                                           }};
                              ({StreamId, Stream=#stream_state{state=half_closed_remote,send_window_size=SWS}}) ->
                               {StreamId, Stream#stream_state{
                                            send_window_size=SWS - Delta
                                           }};
                              (X) -> X
                           end, Streams),
    lager:info("Sending Settings ACK"),
    socksend(S, http2_frame_settings:ack()),
    lager:info("Sent Settings ACK"),
    {next_state, connected, S#connection_state{
                              send_settings=NewSendSettings,
                              streams=NewStreams
                             }};
%% This is the case where we got an ACK, so dequeue settings we're
%% waiting to apply
route_frame({H, _Payload},
            S = #connection_state{
                   settings_sent=SS
                  })
    when H#frame_header.type == ?SETTINGS,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received SETTINGS ACK"),
    case queue:out(SS) of
        {{value, {_Ref, NewSettings}}, NewSS} ->
            {next_state,
             connected,
             S#connection_state{
               settings_sent=NewSS,
               recv_settings=NewSettings
              }};
        X ->
            lager:info("queue:out -> ~p", [X]),
            {next_state, closing, S}
    end;



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stream level frames
%%
%% Maybe abstract it all into http2_stream?

%% TODO Route data frames to streams.
route_frame(F={H=#frame_header{
                  stream_id=StreamId}, _Payload},
            S = #connection_state{
                   streams=Streams,
                   socket=_Socket
                  })
    when H#frame_header.type == ?DATA ->
    lager:debug("Received DATA Frame for Stream ~p", [StreamId]),

    {Stream, NewStreamsTail} = get_stream(StreamId, Streams),

    %% Decrement stream & connection recv_window L happens in http2_stream:recv_frame
    {FinalStream, NewConnectionState} = http2_stream:recv_frame(F, {Stream, S}),

    {next_state, connected, NewConnectionState#connection_state{
                              streams=[{StreamId,FinalStream}|NewStreamsTail]
                             }};

%%%%%%%%%
%% Begin Refactor of headers/continuation into http2_stream

%% Since we don't create idle streams and just assume they exist, we
%% actually need to create a new stream state in two cases (as a
%% server)

%% 1) We have received a HEADERS frame
%% 2) We have sent a PUSH_PROMISE frame

%% First let's worry about HEADERS

%% The only thing we need to know about in this gen_fsm is wether or
%% not we are going to remain in the connected state or transition
%% into the continuation state
route_frame({H=#frame_header{
                  type=?HEADERS,
                  stream_id=StreamId
                 }, _Payload} = Frame,
            S = #connection_state{
                   recv_settings=#settings{initial_window_size=RecvWindowSize},
                   send_settings=#settings{initial_window_size=SendWindowSize},
                   streams = Streams
            }) ->
    lager:debug("Received HEADERS Frame for Stream ~p", [StreamId]),
    %% Three things could be happening here.

    %% 1. We're a server, and these are Request Headers.

    %% 2. We're a client, and these are Response Headers.

    %% 3. We're a client, and these are Response Headers, but the
    %% response is to a Push Promise

    %% Fortunately, the only thing we need to do here is create a new
    %% stream if this is the first scenario. The stream will already
    %% exist if this is a PP or Response
    {Stream, NewTail} =
        case get_stream(StreamId, Streams) of
            notfound ->
                lager:debug("Stream ~p notfound", [StreamId]),
                {http2_stream:new(StreamId, {SendWindowSize, RecvWindowSize}),
                 Streams};
            {NewStream, Tail} ->
                lager:debug("Stream ~p found! ~p", [StreamId, NewStream]),
                {NewStream, Tail}
        end,

    NextState = case ?IS_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS) of
                            true ->
                                connected;
                            false ->
                                continuation
                        end,

    lager:debug("recv(~p, {~p, ~p})",[Frame, Stream, S]),
    R = http2_stream:recv_frame(Frame, {Stream, S}),
    lager:debug("?? ~p",[R]),
    {NewStream1, NewConnectionState} = R,
    {next_state, NextState, NewConnectionState#connection_state{
                                 streams = [{StreamId, NewStream1}|NewTail],
                                 continuation_stream_id = StreamId
                                }};
route_frame(F={H=#frame_header{
                    stream_id=StreamId,
                    type=?CONTINUATION
                   }, _Payload},
            S = #connection_state{
                   streams = Streams
                  }) ->
    lager:debug("Received CONTINUATION Frame for Stream ~p", [StreamId]),
    {Stream, NewStreamsTail} = get_stream(StreamId, Streams),
    {NewStream, NewConnectionState} = http2_stream:recv_frame(F, {Stream, S}),
    NewStreams = [{StreamId,NewStream}|NewStreamsTail],

    NextState = case ?IS_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS) of
                    true ->
                        connected;
                    false ->
                        continuation
                end,

    {next_state, NextState, NewConnectionState#connection_state{
                              streams = NewStreams
                             }};

route_frame({H, _Payload}, S = #connection_state{
                                  socket=_Socket})
    when H#frame_header.type == ?PRIORITY,
         H#frame_header.stream_id == 16#0 ->
    go_away(?PROTOCOL_ERROR, S);
route_frame({H, _Payload}, S = #connection_state{
                                  socket=_Socket})
    when H#frame_header.type == ?PRIORITY ->
    lager:debug("Received PRIORITY Frame, but it's only a suggestion anyway..."),
    {next_state, connected, S};
%% TODO: RST_STREAM support
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #connection_state{
                                                                    streams=Streams,
                                                                    socket=_Socket})
    when H#frame_header.type == ?RST_STREAM ->
    case get_stream(StreamId, Streams) of
        notfound ->
            go_away(?PROTOCOL_ERROR, S);
        _ ->
            lager:error("Received RST_STREAM for Stream ~p, but did nothing with it", [StreamId]),
            {next_state, connected, S}
    end;
%%    {next_state, connected, S#connection_state{settings_sent=SS-1}};
route_frame({
              H=#frame_header{stream_id=StreamId}, _Payload}=F,
            #connection_state{
               streams=Streams
              }=Connection)
    when H#frame_header.type == ?PUSH_PROMISE ->
    lager:debug("Received PUSH_PROMISE Frame for Stream ~p", [StreamId]),
    {Stream, StreamTail} = get_stream(StreamId, Streams),
    {NewStream, NewConnection} =
        http2_stream:recv_frame(F, {Stream, Connection#connection_state{streams=StreamTail}}),



    {next_state,
     connected,
     NewConnection#connection_state{
       streams=[{StreamId, NewStream}|NewConnection#connection_state.streams]
      }};

%% The case for PING

%% If not stream 0, then connection error
route_frame({H, _Payload}, S)
    when H#frame_header.type == ?PING,
         H#frame_header.stream_id =/= 0 ->
    go_away(?PROTOCOL_ERROR, S);
%% If length != 8, FRAME_SIZE_ERROR
route_frame({H, _Payload}, S)
    when H#frame_header.type == ?PING,
         H#frame_header.length =/= 8 ->
    go_away(?FRAME_SIZE_ERROR, S);
%% If PING && !ACK, must ACK
route_frame({H, Ping}, S = #connection_state{})
    when H#frame_header.type == ?PING,
         ?NOT_FLAG(#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received PING"),
    Ack = http2_frame_ping:ack(Ping),
    socksend(S, http2_frame:to_binary(Ack)),
    {next_state, connected, S};
route_frame({H, _Payload}, S = #connection_state{socket=_Socket})
    when H#frame_header.type == ?PING,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received PING ACK"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=0}, _Payload}, S = #connection_state{socket=_Socket})
    when H#frame_header.type == ?GOAWAY ->
    lager:debug("Received GOAWAY Frame for Stream 0"),
    go_away(?NO_ERROR, S);
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #connection_state{socket=_Socket})
    when H#frame_header.type == ?GOAWAY ->
    lager:debug("Received GOAWAY Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this GOAWAY away"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=0}, #window_update{window_size_increment=WSI}},
            S = #connection_state{
                   socket=_Socket,
                   send_window_size=SWS
                  })
    when H#frame_header.type == ?WINDOW_UPDATE ->
    lager:debug("Stream 0 Window Update: ~p", [WSI]),
    {next_state, connected, S#connection_state{send_window_size=SWS+WSI}};
route_frame(F={H=#frame_header{stream_id=StreamId}, #window_update{}},
            S = #connection_state{
                   streams=Streams})
    when H#frame_header.type == ?WINDOW_UPDATE ->
    lager:debug("Received WINDOW_UPDATE Frame for Stream ~p", [StreamId]),
    case lists:keyfind(StreamId, 1, Streams) of
        {StreamId, Stream} ->
            NewStreamsTail = lists:keydelete(StreamId, 1, Streams),
            %NewSendWindow = WSI+Stream#stream_state.send_window_size,
            {NStream, NConn} = http2_stream:recv_frame(F, {Stream, S}),
            %%NStream = chatterbox_static_content_handler:send_while_window_open(Stream#stream_state{send_window_size=NewSendWindow}, C),
            %%NewStreams = [{StreamId, Stream#stream_state{send_window_size=NewSendWindow}}|NewStreamsTail],
            NewStreams = [{StreamId, NStream}|NewStreamsTail],
            {next_state, connected, NConn#connection_state{streams=NewStreams}};
        _ ->
            go_away(?PROTOCOL_ERROR, S)
    end;

%route_frame({error, closed}, State) ->
%    {stop, normal, State};
route_frame(Frame, State) ->
    lager:error("Frame condition not covered by pattern match"),
    lager:error("This is bad and you probably found a bug. Please open a github issue with this output:"),
    lager:error("OOPS! " ++ http2_frame:format(Frame)),
    lager:error("OOPS! ~p", [State]),
    go_away(?PROTOCOL_ERROR, State).

handle_event({send_headers, StreamId, Headers},
             StateName,
             State=#connection_state{
                      encode_context=EncodeContext,
                      streams = Streams
                     }
            ) ->
    lager:debug("{send headers, ~p, ~p}", [StreamId, Headers]),
    {Stream, StreamTail} = get_stream(StreamId, Streams),
    lager:debug("stream ~p", [Stream]),
    {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, Headers, EncodeContext),
    {NewStream, NewConnection} = http2_stream:send_frame(HeaderFrame, {Stream, State}),
    {next_state, StateName, NewConnection#connection_state{
                              encode_context=NewContext,
                              streams=[{StreamId, NewStream}|StreamTail]
                             }};
handle_event({send_body, StreamId, Body},
             StateName,
             State=#connection_state{
                      streams=Streams,
                      send_settings=SendSettings
                     }
            ) ->
    {Stream, StreamTail} = get_stream(StreamId, Streams),
    DataFrames = http2_frame_data:to_frames(StreamId, Body, SendSettings),
    {NewStream, NewConnection}
        = lists:foldl(
            fun(Frame, S) ->
                    http2_stream:send_frame(Frame, S)
            end,
            {Stream, State},
            DataFrames),

    {next_state, StateName, NewConnection#connection_state{
                              streams=[{StreamId, NewStream}|StreamTail]
                             }};
handle_event({send_promise, StreamId, NewStreamId, Headers},
             StateName,
             #connection_state{
                streams=Streams,
                encode_context=OldContext
               }=Connection
            ) ->
    {Stream, StreamTail} = get_stream(StreamId, Streams),
    {PromiseFrame, NewContext} = http2_frame_push_promise:to_frame(
                                   StreamId,
                                   NewStreamId,
                                   Headers,
                                   OldContext
                                  ),
    {NewStream, NewConnection} =
        http2_stream:send_frame(PromiseFrame,
                                {Stream,
                                 Connection#connection_state{
                                   streams=StreamTail
                                  }
                                }),

    {X,_} = get_stream(NewStreamId, NewConnection#connection_state.streams),
    lager:debug("Promise sent, Stream: ~p", [X]),

    {next_state, StateName, NewConnection#connection_state{
                              encode_context=NewContext,
                              streams=[{StreamId, NewStream}|NewConnection#connection_state.streams]
                             }};

handle_event({check_settings_ack, {Ref, NewSettings}},
             StateName,
             State=#connection_state{
                      settings_sent=SS
                     }) ->
    case queue:out(SS) of
        {{value, {Ref, NewSettings}}, _} ->
            %% This is still here!
            go_away(?SETTINGS_TIMEOUT, State);
        _ ->
            %% YAY!
            {next_state, StateName, State}
    end;
handle_event({send_bin, Binary}, StateName, State) ->
    socksend(State, Binary),
    {next_state, StateName, State};
handle_event({send_frame, Frame}, StateName, State) ->
    Binary = http2_frame:to_binary(Frame),
    socksend(State, Binary),
    {next_state, StateName, State};
handle_event(stop, _StateName, State) ->
    go_away(0, State);
handle_event(_E, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event({get_response, StreamId}, _F, StateName,
                  #connection_state{
                     streams=Streams
                    }=Connection) ->
    {Stream, _} = get_stream(StreamId, Streams),
    Reply =
        case Stream#stream_state.response_end_stream of
            true ->
                {ok, {Stream#stream_state.response_headers,
                      Stream#stream_state.response_body}};
            false ->
                {error, stream_not_finished}
        end,
    {reply, Reply, StateName, Connection};
handle_sync_event({new_stream, NotifyPid}, _F, StateName,
                  State=#connection_state{
                           streams=Streams,
                           next_available_stream_id=NextId,
                           recv_settings=#settings{initial_window_size=RecvWindowSize},
                           send_settings=#settings{initial_window_size=SendWindowSize}
                          }) ->
    NewStream = http2_stream:new(NextId, {SendWindowSize, RecvWindowSize}),
    lager:debug("added stream #~p to ~p", [NextId, Streams]),
    {reply, NextId, StateName, State#connection_state{
                                 next_available_stream_id=NextId+2,
                                 streams=[{NextId, NewStream#stream_state{notify_pid=NotifyPid}}|Streams]
                                }};
handle_sync_event(is_push, _F, StateName,
                  State=#connection_state{
                    send_settings=#settings{enable_push=Push}
                   }) ->
    IsPush = case Push of
        1 -> true;
        _ -> false
    end,
    {reply, IsPush, StateName, State};
handle_sync_event(get_peer, _F, StateName, State=#connection_state{socket={Transport,Socket}}) ->
    Module = case Transport of
                 gen_tcp -> inet;
                 ssl -> ssl
             end,
    case Module:peername(Socket) of
        {error, _}=Error ->
            lager:warning("failed to fetch peer for ~p socket", [Module]),
            {reply, Error, StateName, State};
        {ok, _AddrPort}=OK ->
            {reply, OK, StateName, State}
    end;
handle_sync_event(_E, _F, StateName, State) ->
    {next_state, StateName, State}.


handle_info({inet_async, ListenSocket, Ref, {ok, ClientSocket}},
            listen,
            #h2_listening_state{
               listen_socket = ListenSocket,
               listen_ref = Ref,
               transport = Transport,
               ssl_options = SSLOptions,
               acceptor_callback = AcceptorCallback
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
    start_http2_server(#connection_state{
                          socket={Transport, Socket}
                         });


%% Socket Messages
%% {tcp, Socket, Data}
handle_info({tcp, Socket, Data},
            StateName,
            #connection_state{
               socket={gen_tcp,Socket}
              }=State) ->
    handle_socket_data(Data, StateName, State);
%% {ssl, Socket, Data}
handle_info({ssl, Socket, Data},
            StateName,
            #connection_state{
               socket={ssl,Socket}
              }=State) ->
    handle_socket_data(Data, StateName, State);
%% {tcp_passive, Socket}
handle_info({tcp_passive, Socket},
            StateName,
            #connection_state{
               socket={gen_tcp, Socket}
              }=State) ->
    handle_socket_passive(StateName, State);
%% {tcp_closed, Socket}
handle_info({tcp_closed, Socket},
            StateName,
            #connection_state{
              socket={gen_tcp, Socket}
             }=State) ->
    handle_socket_closed(StateName, State);
%% {ssl_closed, Socket}
handle_info({ssl_closed, Socket},
            StateName,
            #connection_state{
               socket={ssl, Socket}
              }=State) ->
    handle_socket_closed(StateName, State);
%% {tcp_error, Socket, Reason}
handle_info({tcp_error, Socket, Reason},
            StateName,
            #connection_state{
               socket={gen_tcp,Socket}
              }=State) ->
    handle_socket_error(Reason, StateName, State);
%% {ssl_error, Socket, Reason}
handle_info({ssl_error, Socket, Reason},
            StateName,
            #connection_state{
               socket={ssl,Socket}
              }=State) ->
    handle_socket_error(Reason, StateName, State);
handle_info({_,R}=M, StateName, State) ->
    lager:error("BOOM! ~p", [M]),
    handle_socket_error(R, StateName, State).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    lager:debug("terminate reason: ~p~n", [_Reason]).


-spec get_stream(stream_id(), [{stream_id(), stream_state()}]) ->
                        {stream_state(), [{stream_id(), stream_state()}]}
                            | notfound | toomany.
get_stream(StreamId, Streams) ->


    case lists:partition(fun({Sid, _}) ->
                                 Sid =:= StreamId
                         end,
                         Streams) of
        {[{StreamId, Stream}], Leftovers} ->
            {Stream, Leftovers};
        {[], Streams} ->
            notfound;
        _ ->
            toomany
        end.

-spec go_away(error_code(), #connection_state{}) -> {next_state, closing, #connection_state{}}.
go_away(ErrorCode,
         State = #connection_state{
                    next_available_stream_id=NAS
                  }) ->
    GoAway = #goaway{
                last_stream_id=NAS, %% maybe not the best idea.
                error_code=ErrorCode
               },
    GoAwayBin = http2_frame:to_binary({#frame_header{
                                          stream_id=0
                                         }, GoAway}),
    socksend(State, GoAwayBin),
    gen_fsm:send_event(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    {next_state, closing, State}.

-spec send_settings(connection_state()) -> connection_state().
send_settings(State = #connection_state{
                         recv_settings=CurrentSettings,
                         settings_sent=SS
                        }) ->
    %% Pull from config
    NewSettings = chatterbox:settings(),
    Ref = make_ref(),

    Bin = http2_frame_settings:send(CurrentSettings, NewSettings),
    socksend(State, Bin),
    send_ack_timeout({Ref,NewSettings}),
    State#connection_state{
      settings_sent=queue:in({Ref, NewSettings}, SS)
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
active_once({Transport, Socket}) ->
    T = case Transport of
        ssl -> ssl;
        gen_tcp -> inet
    end,
    T:setopts(Socket, [{active, once}]).

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

start_http2_server(#connection_state{
                     socket={Transport, Socket}
                    }=State) ->
    case Transport:recv(Socket, length(?PREFACE), 5000) of
        {ok, <<?PREFACE>>} ->
            ok = active_once({Transport, Socket}),
            NewState =              State#connection_state{
               next_available_stream_id=2
              },
            {next_state,
             handshake,
             send_settings(NewState)
            };
        BadPreface ->
            lager:debug("Bad Preface: ~p", [BadPreface]),
            go_away(?PROTOCOL_ERROR, State)
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
                   #connection_state{
                      socket={Transport,Socket}
                     }=State) ->
    active_once({Transport, Socket}),
    {next_state, StateName, State};
handle_socket_data(Data,
                   StateName,
                   #connection_state{
                      socket={Transport, Socket},
                      buffer=Buffer
                     }=State) ->

    More = case Transport:recv(Socket, 0, 1) of %% fail fast!
        {ok, Rest} ->
            Rest;
        %% It's not really an error, it's what we want
        {error, timeout} ->
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
    NewState = State#connection_state{buffer=empty},

    case http2_frame:recv(ToParse) of
        %% We got a full frame, ship it off to the FSM
        {ok, Frame, Rem} ->
            gen_fsm:send_event(self(), {frame, Frame}),
            handle_socket_data(Rem, StateName, NewState);
        %% Not enough bytes left to make a header :(
        {error, not_enough_header, Bin} ->
            {next_state, StateName, NewState#connection_state{buffer={binary, Bin}}};
        %% Not enough bytes to make a payload
        {error, not_enough_payload, Header, Bin} ->
            {next_state, StateName, NewState#connection_state{buffer={frame, Header, Bin}}}
    end.

handle_socket_passive(StateName, State) ->
    {next_state, StateName, State}.

handle_socket_closed(_StateName, State) ->
    {stop, normal, State}.

handle_socket_error(Reason, _StateName, State) ->
    {stop, Reason, State}.

socksend(#connection_state{
            socket={Transport, Socket},
            type=T
           }, Data) ->
    case Transport:send(Socket, Data) of
        ok ->
            ok;
        {error, Reason} ->
            lager:debug("~p {error, ~p} sending, ~p", [T, Reason, Data]),
            {error, Reason}
    end.
