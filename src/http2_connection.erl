-module(http2_connection).

-behaviour(gen_fsm).

-include("http2.hrl").

-export([start_link/1]).

-export([
         send_headers/3,
         send_body/3,
         is_push/1,
         new_stream/1,
         send_promise/4
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

-export([go_away/2]).

-spec start_link({gen_tcp, socket()}|{ssl, ssl:sslsocket()}) ->
                        {ok, pid()} |
                        ignore |
                        {error, term()}.
start_link(Socket) ->
    gen_fsm:start_link(?MODULE, Socket, []).


-spec send_headers(pid(), stream_id(), hpack:headers()) -> ok.
send_headers(Pid, StreamId, Headers) ->
    gen_fsm:send_all_state_event(Pid, {send_headers, StreamId, Headers}),
    ok.

-spec send_body(pid(), stream_id(), binary()) -> ok.
send_body(Pid, StreamId, Body) ->
    gen_fsm:send_all_state_event(Pid, {send_body, StreamId, Body}),
    ok.

-spec is_push(pid()) -> boolean().
is_push(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, is_push).

-spec new_stream(pid()) -> stream_id().
new_stream(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, new_stream).

-spec send_promise(pid(), stream_id(), stream_id(), hpack:headers()) -> ok.
send_promise(Pid, StreamId, NewStreamId, Headers) ->
    gen_fsm:send_all_state_event(Pid, {send_promise, StreamId, NewStreamId, Headers}),
    ok.

-spec init([socket() | term()]) ->
                  {ok, accept, #connection_state{}}.
init([{Transport, ListenSocket}, SSLOptions]) ->
    {ok, Ref} = prim_inet:async_accept(ListenSocket, -1),
    {ok,
     accept,
     #connection_state{
        listen_ref=Ref,
        socket = {Transport, undefined},
        ssl_options = SSLOptions
        }}.

%% accepting connection state:
-spec handshake(timeout, #connection_state{}) ->
                    {next_state, connected|closing, #connection_state{}, non_neg_integer()}.
handshake(timeout,
          StateWithSocket=#connection_state{
            socket={Transport, Socket}
          }) ->
    case Transport:recv(Socket, length(?PREAMBLE), 5000) of
        {ok, <<?PREAMBLE>>} ->
            %% From Section 6.5 of the HTTP/2 Specification A SETTINGS
            %% frame MUST be sent by both endpoints at the start of a
            %% connection, and MAY be sent at any other time by either
            %% endpoint over the lifetime of the
            %% connection. Implementations MUST support all of the
            %% parameters defined by this specification.

            StateToRouteWith = send_settings(StateWithSocket),

            %% The first frame should be the client settings as per
            %% RFC-7540#3.5

            Frame = {FH, _FPayload} = http2_frame:read({Transport,Socket}, 5000),

            try FH#frame_header.type of
                ?SETTINGS ->
                    route_frame(Frame, StateToRouteWith);
                _ ->
                    go_away(?PROTOCOL_ERROR, StateToRouteWith)
            catch
                _:_ ->
                    go_away(?PROTOCOL_ERROR, StateToRouteWith)
            end;
        BadPreamble ->
            lager:debug("Bad Preamble: ~p", [BadPreamble]),
            go_away(?PROTOCOL_ERROR, StateWithSocket)
    end.

connected(timeout,
          S = #connection_state{
                 socket = Socket
                }
         ) ->
    %% Timeout here so we can come up for air and see if anybody is
    %% asking us to do anything. like maybe somebody has come to check
    %% if we ever got our server settings ack
    Response = case http2_frame:read(Socket, 1) of
        {error, _} ->
             {next_state, connected, S, 0};
        Frame ->
            lager:debug("[connected] [next] ~p", [http2_frame:format(Frame)]),
            route_frame(Frame, S)
    end,
    Response.

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state
continuation(timeout,
             S = #connection_state{
                    socket=Socket,
                    continuation_stream_id = StreamId
                   }) ->
    %lager:debug("[continuation] Waiting for next frame"),
    Response =
        case http2_frame:read(Socket, 1) of
            {error, _} ->
                {next_state, continuation, S, 0};
            Frame = {#frame_header{
                     stream_id=StreamId,
                     type=?CONTINUATION
                    }, _} ->
                lager:debug("[continuation] [next] ~p", [http2_frame:format(Frame)]),
                route_frame(Frame, S);
            Frame ->
                lager:debug("[continuation] [next] ~p", [http2_frame:format(Frame)]),
                go_away(?PROTOCOL_ERROR, S)
        end,
    Response;
continuation(_, State) ->
    go_away(?PROTOCOL_ERROR, State).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.

closing(Message, State=#connection_state{
        socket={Transport, Socket}
    }) ->
    lager:debug("[closing] ~p", [Message]),
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
     #connection_state{}, non_neg_integer()}.
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
                                 socket=Socket,
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

    http2_frame_settings:ack(Socket),
    {next_state, connected, S#connection_state{
                              send_settings=NewSendSettings,
                              streams=NewStreams
                             }, 0
    };
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
              }, 0};
        _ ->
            {next_state, closing, S, 0}
    end;



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stream level frames
%%
%% Maybe abstract it all into http2_stream?

%% TODO Route data frames to streams. POST!
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
                             }, 0
    };

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
    %% ok, it's a headers frame. No matter what, create a new stream.
    NewStream = http2_stream:new(StreamId, {SendWindowSize, RecvWindowSize}),

    NextState = case ?IS_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS) of
                    true ->
                        connected;
                    false ->
                        continuation
                end,
    {NewStream1, NewConnectionState} = http2_stream:recv_frame(Frame, {NewStream, S}),
    {next_state, NextState, NewConnectionState#connection_state{
                                 streams = [{StreamId, NewStream1}|Streams],
                                 continuation_stream_id = StreamId
                                }, 0
    };

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
                             }, 0};

route_frame({H, _Payload}, S = #connection_state{
                                  socket=_Socket})
    when H#frame_header.type == ?PRIORITY,
         H#frame_header.stream_id == 16#0 ->
    go_away(?PROTOCOL_ERROR, S);
route_frame({H, _Payload}, S = #connection_state{
                                  socket=_Socket})
    when H#frame_header.type == ?PRIORITY ->
    lager:debug("Received PRIORITY Frame, but it's only a suggestion anyway..."),
    {next_state, connected, S, 0};
%% TODO: RST_STREAM support
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #connection_state{
                                                                    socket=_Socket})
    when H#frame_header.type == ?RST_STREAM ->
    lager:debug("Received RST_STREAM Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this RST_STREAM away"),
    {next_state, connected, S, 0};
%%    {next_state, connected, S#connection_state{settings_sent=SS-1}};
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #connection_state{})
    when H#frame_header.type == ?PUSH_PROMISE ->
    lager:debug("Received PUSH_PROMISE Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support SERVER_PUSH. Throwing this PUSH_PROMISE away"),
    {next_state, connected, S, 0};

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
route_frame({H, Ping}, S = #connection_state{socket={Transport,Socket}})
    when H#frame_header.type == ?PING,
         ?NOT_FLAG(#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received PING"),
    Ack = http2_frame_ping:ack(Ping),
    Transport:send(Socket, http2_frame:to_binary(Ack)),
    {next_state, connected, S, 0};
route_frame({H, _Payload}, S = #connection_state{socket=_Socket})
    when H#frame_header.type == ?PING,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received PING ACK"),
    {next_state, connected, S, 0};
route_frame({H=#frame_header{stream_id=0}, _Payload}, S = #connection_state{socket=_Socket})
    when H#frame_header.type == ?GOAWAY ->
    lager:debug("Received GOAWAY Frame for Stream 0"),
    go_away(?NO_ERROR, S);
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #connection_state{socket=_Socket})
    when H#frame_header.type == ?GOAWAY ->
    lager:debug("Received GOAWAY Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this GOAWAY away"),
    {next_state, connected, S, 0};
route_frame({H=#frame_header{stream_id=0}, #window_update{window_size_increment=WSI}},
            S = #connection_state{
                   socket=_Socket,
                   send_window_size=SWS
                  })
    when H#frame_header.type == ?WINDOW_UPDATE ->
    lager:debug("Stream 0 Window Update: ~p", [WSI]),
    {next_state, connected, S#connection_state{send_window_size=SWS+WSI}, 0};
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
            {next_state, connected, NConn#connection_state{streams=NewStreams}, 0};
        _ ->
            lager:error("Window update for a stream that we don't think exists!"),
            {next_state, connected, S, 0}
    end;

%route_frame({error, closed}, State) ->
%    {stop, normal, State};
route_frame(Frame, State) ->
    lager:error("Frame condition not covered by pattern match"),
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
    {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, Headers, EncodeContext),
    {NewStream, NewConnection} = http2_stream:send_frame(HeaderFrame, {Stream, State}),
    {next_state, StateName, NewConnection#connection_state{
                              encode_context=NewContext,
                              streams=[{StreamId, NewStream}|StreamTail]
                             }, 0
    };
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
                             }, 0
    };
handle_event({send_promise, StreamId, NewStreamId, Headers},
             StateName,
             State=#connection_state{
                      streams=Streams,
                      encode_context=OldContext
                     }
            ) ->
    {Stream, StreamTail} = get_stream(StreamId, Streams),
    {PromiseFrame, NewContext} = http2_frame_push_promise:to_frame(
                                   StreamId,
                                   NewStreamId,
                                   Headers,
                                   OldContext
                                  ),
    {NewStream, NewConnection} = http2_stream:send_frame(PromiseFrame, {Stream, State}),
    {next_state, StateName, NewConnection#connection_state{
                              encode_context=NewContext,
                              streams=[{StreamId, NewStream}|StreamTail]
                             }, 0
    };

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
            {next_state, StateName, State, 0}
    end;
handle_event(_E, StateName, State) ->
    {next_state, StateName, State, 0}.

handle_sync_event(new_stream, _F, StateName,
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
                                 streams=[{NextId, NewStream}|Streams]
                                }, 0
    };
handle_sync_event(is_push, _F, StateName,
                  State=#connection_state{
                    send_settings=#settings{enable_push=Push}
                   }) ->
    IsPush = case Push of
        1 -> true;
        _ -> false
    end,
    {reply, IsPush, StateName, State, 0};
handle_sync_event(_E, _F, StateName, State) ->
    {next_state, StateName, State, 0}.

handle_info({inet_async, _ListSock, Ref, {ok, CliSocket}},
    accept,
    S=#connection_state{
        ssl_options = SSLOptions,
        socket = {Transport, undefined},
        listen_ref = Ref
    }) ->
    inet_db:register_socket(CliSocket, inet_tcp),
    Socket = case Transport of
        gen_tcp ->
            CliSocket;
        ssl ->
            {ok, AcceptSocket} = ssl:ssl_accept(CliSocket, SSLOptions),
            %% TODO: Erlang 18 uses ALPN
            {ok, _Upgrayedd} = ssl:negotiated_protocol(AcceptSocket),
            AcceptSocket
        end,
    chatterbox_sup:start_socket(),

    {next_state,
     handshake,
     S#connection_state{
       socket = {Transport, Socket}
     },
     0};
%% TODO: Handle_info when ssl socket is closed
handle_info({tcp_closed, _Socket}, _StateName, S) ->
    lager:debug("tcp_close"),
    {stop, normal, S};
handle_info({tcp_error, _Socket, _}, _StateName, S) ->
    lager:debug("tcp_error"),
    {stop, normal, S};
handle_info(E, StateName, S) ->
    lager:debug("unexpected [~p]: ~p~n", [StateName, E]),
    {next_state, StateName , S, 0}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    lager:debug("terminate reason: ~p~n", [_Reason]).


-spec get_stream(stream_id(), [{stream_id(), stream_state()}]) ->
                        {stream_state(), [{stream_id(), stream_state()}]}.
get_stream(StreamId, Streams) ->
    {[{StreamId, Stream}], Leftovers} =
        lists:partition(fun({Sid, _}) ->
                                Sid =:= StreamId
                        end,
                        Streams),
    {Stream, Leftovers}.

-spec go_away(error_code(), #connection_state{}) -> {next_state, closing, #connection_state{}, non_neg_integer()}.
go_away(ErrorCode,
         State = #connection_state{
                   socket={T,Socket},
                    next_available_stream_id=NAS
                  }) ->
    GoAway = #goaway{
                last_stream_id=NAS, %% maybe not the best idea.
                error_code=ErrorCode
               },
    GoAwayBin = http2_frame:to_binary({#frame_header{
                                          stream_id=0
                                         }, GoAway}),
    T:send(Socket, GoAwayBin),
    gen_fsm:send_event(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    {next_state, closing, State, 0}.

-spec send_settings(connection_state()) -> connection_state().
send_settings(State = #connection_state{
                         recv_settings=CurrentSettings,
                         socket=Socket,
                         settings_sent=SS
                        }) ->
    %% Pull from config
    NewSettings = chatterbox:settings(),
    Ref = make_ref(),

    http2_frame_settings:send(Socket, CurrentSettings, NewSettings),
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
