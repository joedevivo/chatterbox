-module(http2_connection).

-behaviour(gen_fsm).

-include("http2.hrl").

-export([start_link/1]).

%% gen_fsm callbacks
-export([
    init/1,
    handle_event/3,
    handle_sync_event/4,
    handle_info/3,
    code_change/4,
    terminate/3
]).

-export([accept/2,
         settings_handshake/2,
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

-spec init(socket()) ->
                  {ok, accept, #connection_state{}}.
init({Transport, ListenSocket}) ->
    gen_fsm:send_event(self(), {Transport, ListenSocket}),
    {ok, accept, #connection_state{}}.

%% accepting connection state:
-spec accept(socket(), #connection_state{}) ->
                    {next_state, settings_handshake, #connection_state{}}.
accept({Transport, ListenSocket}, InitialState) ->
    Socket = case Transport of
        gen_tcp ->
            %%TCP Version
            {ok, AcceptSocket} = Transport:accept(ListenSocket),
            AcceptSocket;
        ssl ->
            %% SSL conditional stuff
            {ok, AcceptSocket} = Transport:transport_accept(ListenSocket),
            _Accept = ssl:ssl_accept(AcceptSocket),
            %% TODO: Erlang 18 uses ALPN
            {ok, _Upgrayedd} = ssl:negotiated_next_protocol(AcceptSocket),
            AcceptSocket
    end,
    %% Start up a listening socket to take the place of this socket,
    %% that's no longer listening
    chatterbox_sup:start_socket(),

    {ok, Bin} = Transport:recv(Socket, length(?PREAMBLE), 5000),
    case Bin of
        <<?PREAMBLE>> ->
            gen_fsm:send_event(self(), start),
            {next_state,
             settings_handshake,
             InitialState#connection_state{socket={Transport,Socket}}};
        BadPreamble ->
            Transport:close(Socket),
            lager:debug("Bad Preamble: ~p", [BadPreamble]),
            go_away(?PROTOCOL_ERROR, InitialState)
    end.

%% From Section 6.5 of the HTTP/2 Specification
%% A SETTINGS frame MUST be sent by both endpoints at the start of a
%% connection, and MAY be sent at any other time by either endpoint
%% over the lifetime of the connection. Implementations MUST support
%% all of the parameters defined by this specification.
-spec settings_handshake(start | {boolean(), boolean(), [frame()]},
                         #connection_state{}) ->
                                {next_state, settings_handshake | connected, #connection_state{}}
                              | {stop, closing, #connection_state{}}.
settings_handshake(start, S = #connection_state{
                                              socket=Socket,
                                              recv_settings=ServerSettings
                                             }) ->
    %% Assemble our settings and send them
    http2_frame_settings:send(Socket, ServerSettings),

    %% There should be two SETTINGS frames sitting on the wire
    %% now. The ACK to the one we just sent and the value of the
    %% client settings. We're pretty sure that the first one will be
    %% the Client Settings as it was probably on the wire before we
    %% even sent the Server Settings, but can we ever really be sure

    %% What we know from the HTTP/2 spec is that we shouldn't process
    %% any other frame types until SETTINGS have been exchanged. So,
    %% if something else comes in, let's store them in a backlog until
    %% we can deal with them

    NewState = S#connection_state{
                 frame_backlog=queue:new()
                },
    gen_fsm:send_event(self(), {false, false, []}),
    {next_state, settings_handshake, NewState};

%% For the remaining settings_handshake clauses, the event is
%% {boolean(), boolean(), [frame()]} which was formerly the
%% accumulator for settings_handhshake_loop (for you chatterbox
%% historians out there!)

%% The event is {true, true, []} when the SETTINGS handshake is
%% complete. We're done, transition to connected and start processing
%% the backlog %settings_handshake_loop({true, true}, [], State) ->
settings_handshake({true, true, []}, State) ->
    gen_fsm:send_event(self(), backlog),
    {next_state, connected, State};
%% We're done with anything we received on the initial packet, read
%% another, and put it on the backlog. We don't really need to do
%% this, except it lets us only write the conditional logic once
settings_handshake({ReceivedAck,ReceivedClientSettings,[]}, State=#connection_state{
                                           socket=Socket,
                                           frame_backlog=FB
                                          }) ->
    %% TODO: 5000 is hardcoded, make configurable
    Frame = {FH, _} = http2_frame:read(Socket, 5000),

    try FH#frame_header.type of
        ?SETTINGS ->
            gen_fsm:send_event(self(), {ReceivedAck, ReceivedClientSettings, [Frame]}),
            {next_state, settings_handshake, State};
        _ ->
            %% loop right back into this state after putting one on the backlog
            gen_fsm:send_event(self(), {ReceivedAck, ReceivedClientSettings, []}),
            {next_state, settings_handshake, State#connection_state{
                                               frame_backlog=queue:in(Frame, FB)
                                              }}
    catch
        %% Timeout of settings handshake, let's close it down
        _:_ ->
            lager:error("[settings_handshake] did not receive SETTINGS frame in a reasonable timeframe. closing connection"),
            go_away(?SETTINGS_TIMEOUT, State),
            {next_state, closing, State}
    end;
settings_handshake({_ReceivedAck, ReceivedClientSettings,
                    [{FH, _FPayload}|SettingsFramesTail]},
                    State)
  when ?IS_FLAG(FH#frame_header.flags, ?FLAG_ACK) ->
    gen_fsm:send_event(self(), {true, ReceivedClientSettings, SettingsFramesTail}),
    {next_state, settings_handshake, State};
settings_handshake({ReceivedAck, _ReceivedClientSettings, [{_FH, FPayload}|SettingsFramesTail]},
                       S=#connection_state{}) ->
    ClientSettings = http2_frame_settings:overlay(S#connection_state.send_settings, FPayload),
    http2_frame_settings:ack(S#connection_state.socket),

    gen_fsm:send_event(self(), {ReceivedAck, true, SettingsFramesTail}),
    {next_state, settings_handshake, S#connection_state{
                                       send_settings=ClientSettings
                                      }}.

%% Process the backlog during the handshake until there's none
connected(backlog, S = #connection_state{frame_backlog=FB}) ->
    lager:debug("[connected] Processing backlog, length: ~p", [queue:len(FB)]),
    case queue:out(FB) of
        %% Once the backlog is empty, start processing frames as they come in
        {empty, _} ->
            gen_fsm:send_event(self(), start_frame),
            {next_state, connected, S};
        %% After settings handshake, process any backlogged frames
        {{value, F}, T} ->
            Response = route_frame(F, S#connection_state{frame_backlog=T}),
            gen_fsm:send_event(self(), backlog),
            Response
    end;
connected(start_frame,
          S = #connection_state{
                 socket=Socket
                }
         ) ->
    lager:debug("[connected] Waiting for next frame"),
    {_Header, _Payload} = Frame = http2_frame:read(Socket),

    lager:debug("[connected] [start_frame] ~p", [http2_frame:format(Frame)]),

    Response = route_frame(Frame, S),
    %% After frame is routed, let the FSM know we're ready for another
    gen_fsm:send_event(self(), start_frame),
    Response.

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state
continuation(start_frame,
             S = #connection_state{
                    socket=Socket,
                    continuation_stream_id = StreamId
                   }) ->
    Frame = {FH,_} = http2_frame:read(Socket),
    lager:debug("[continuation] [start_frame] ~p", [http2_frame:format(Frame)]),

    Response = case {FH#frame_header.stream_id, FH#frame_header.type} of
                   {StreamId, ?CONTINUATION} ->
                       route_frame(Frame, S);
                   _ ->
                       go_away(?PROTOCOL_ERROR, S)
               end,
    gen_fsm:send_event(self(), start_frame),
    Response;
continuation(_, State) ->
    go_away(?PROTOCOL_ERROR, State).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.
%% TODO: Rethink cleanup.
closing(Message, State) ->
    lager:debug("[closing] ~p", [Message]),
    {stop, normal, State}.
%% Maybe use something like this for readability later
%% -define(SOCKET_PM, #http2_connection_state{socket=Socket}).

%% route_frame's job needs to be "now that we've read a frame off the
%% wire, do connection based things to it and/or forward it to the
%% http2 stream processor (http2_stream:recv_frame)
-spec route_frame(frame() | {error, term()}, #connection_state{}) ->
    {next_state, connected, #connection_state{}}.
%% Bad Length of frame, exceedes maximum allowed size
route_frame({#frame_header{length=L}, _},
            S = #connection_state{
                   recv_settings=#settings{max_frame_size=MFS}
                  })
    when L > MFS ->
    go_away(?FRAME_SIZE_ERROR, S);

%%TODO Data to stream 0 bad
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
                             }
    };

%% HEADERS frame can have an ?FLAG_END_STREAM but no ?FLAG_END_HEADERS
%% in which case, CONTINUATION frame may follow that have an
%% ?FLAG_END_HEADERS. RFC7540:8.1

%% If there CONTINUATIONS, they must all follow the HEADERS frame with
%% no frames from other streams or types in between RFC7540:8.1

%% HEADERS frame with no END_HEADERS flag, expect continuations
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}=Frame,
            S = #connection_state{
                   recv_settings=#settings{initial_window_size=RecvWindowSize},
                   send_settings=#settings{initial_window_size=SendWindowSize},
                   streams = Streams
            })
  when H#frame_header.type == ?HEADERS,
       ?NOT_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS) ->
    lager:debug("Received HEADERS Frame for Stream ~p, no END in sight", [StreamId]),
    NewStream = http2_stream:new(StreamId, {SendWindowSize, RecvWindowSize}),
    {NewStream1, NewConnectionState} = http2_stream:recv_frame(Frame, {NewStream, S}),
    {next_state, continuation, NewConnectionState#connection_state{
                                 streams = [{StreamId, NewStream1}|Streams],
                                 continuation_stream_id = StreamId
                                }
    };
%% HEADER frame with END_HEADERS flag
route_frame(F={H=#frame_header{stream_id=StreamId}, _Payload},
        S = #connection_state{
               decode_context=DecodeContext,
               recv_settings=#settings{initial_window_size=RecvWindowSize},
               send_settings=#settings{initial_window_size=SendWindowSize},
               streams=_Streams,
               content_handler = Handler
           })
    when H#frame_header.type == ?HEADERS,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS) ->
    lager:debug("Received HEADERS Frame for Stream ~p", [StreamId]),
    HeadersBin = http2_frame_headers:from_frames([F]),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),
    %%lager:debug("Headers decoded: ~p", [Headers]),
    Stream = http2_stream:new(StreamId, {SendWindowSize, RecvWindowSize}),
    {Stream2, NextConnectionState} = http2_stream:recv_frame(F, {Stream, S#connection_state{
                                                                           decode_context=NewDecodeContext
                                                                 }}),
    %% Now this stream should be 'open' and because we've gotten ?END_HEADERS we can start processing it.

    %% TODO: Or can we? We should be able to handle data frames here, so maybe
    %% ?END_STREAM is what we should be looking for

    %% TODO: Make this module name configurable
    %% Make content_handler a behavior with handle/3
    {NewStreamState, NewConnectionState} =
        Handler:handle(
          NextConnectionState,
          Headers,
          Stream2),
    %% send it this headers frame which should transition it into the open state
    %% Add that pid to the set of streams in our state
    {next_state, connected, NewConnectionState#connection_state{
                              streams = [{StreamId, NewStreamState}|NewConnectionState#connection_state.streams]
                             }};
%% Might as well do continuations here since they're related code:
route_frame(F={H=#frame_header{stream_id=StreamId}, _Payload},
            S = #connection_state{
                   streams = Streams
                  })
  when H#frame_header.type == ?CONTINUATION,
       ?NOT_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS) ->
    lager:debug("Received CONTINUATION Frame for Stream ~p", [StreamId]),

    {Stream, NewStreamsTail} = get_stream(StreamId, Streams),

    {NewStream, NewConnectionState} = http2_stream:recv_frame(F, {Stream, S}),

    %% TODO: NewStreams = replace old stream
    NewStreams = [{StreamId,NewStream}|NewStreamsTail],

    {next_state, continuation, NewConnectionState#connection_state{
                              streams = NewStreams
                             }};

route_frame(F={H=#frame_header{stream_id=StreamId}, _Payload},
            S = #connection_state{
                   decode_context=DecodeContext,
                   socket=_Socket,
                   streams = Streams,
                   content_handler = Handler
                  })
  when H#frame_header.type == ?CONTINUATION,
       ?IS_FLAG(H#frame_header.flags, ?FLAG_END_HEADERS) ->
    lager:debug("Received CONTINUATION Frame for Stream ~p", [StreamId]),

    {Stream, NewStreamsTail} = get_stream(StreamId, Streams),

    {NewStream, NextConnectionState} = http2_stream:recv_frame(F, {Stream, S}),

    HeaderFrames = lists:reverse(NewStream#stream_state.incoming_frames),
    HeadersBin = http2_frame_headers:from_frames(HeaderFrames),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),

    %% I think this might be wrong because ?END_HEADERS doesn't mean
    %% data has posted but baby steps
    {NewStreamState, NewConnectionState} =
        Handler:handle(
          NextConnectionState#connection_state{decode_context=NewDecodeContext,
                                              streams=NewStreamsTail},
          Headers,
          NewStream),

    NewStreams = [{StreamId,NewStreamState}|NewConnectionState#connection_state.streams],
    {next_state, connected, NewConnectionState#connection_state{
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
                                                                    socket=_Socket})
    when H#frame_header.type == ?RST_STREAM ->
    lager:debug("Received RST_STREAM Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this RST_STREAM away"),
    {next_state, connected, S};
%% Got a settings frame, need to ACK
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

    %% Need a way of processing settings so I know which ones came in on this one payload.
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
                             }
    };
%% Got settings ACK
route_frame({H, _Payload}, S = #connection_state{})
    when H#frame_header.type == ?SETTINGS,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received SETTINGS ACK"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #connection_state{})
    when H#frame_header.type == ?PUSH_PROMISE ->
    lager:debug("Received PUSH_PROMISE Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support SERVER_PUSH. Throwing this PUSH_PROMISE away"),
    {next_state, connected, S};

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
    {StreamId, Stream} = lists:keyfind(StreamId, 1, Streams),
    NewStreamsTail = lists:keydelete(StreamId, 1, Streams),
    %NewSendWindow = WSI+Stream#stream_state.send_window_size,


    {NStream, NConn} = http2_stream:recv_frame(F, {Stream, S}),
    %%NStream = chatterbox_static_content_handler:send_while_window_open(Stream#stream_state{send_window_size=NewSendWindow}, C),
    %%NewStreams = [{StreamId, Stream#stream_state{send_window_size=NewSendWindow}}|NewStreamsTail],
    NewStreams = [{StreamId, NStream}|NewStreamsTail],
    {next_state, connected, NConn#connection_state{streams=NewStreams}};

route_frame({error, closed}, State) ->
    {stop, normal, State};
route_frame(Frame, State) ->
    lager:error("Frame condition not covered by pattern match"),
    lager:error("OOPS! " ++ http2_frame:format(Frame)),
    lager:error("OOPS! ~p", [State]),
    go_away(?PROTOCOL_ERROR, State).

handle_event(_E, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_E, _F, StateName, State) ->
    {next_state, StateName, State}.

%% TODO: Handle_info when ssl socket is closed
handle_info({tcp_closed, _Socket}, _StateName, S) ->
    lager:debug("tcp_close"),
    {stop, normal, S};
handle_info({tcp_error, _Socket, _}, _StateName, S) ->
    lager:debug("tcp_error"),
    {stop, normal, S};
handle_info(E, StateName, S) ->
    lager:debug("unexpected [~p]: ~p~n", [StateName, E]),
    {next_state, StateName , S}.

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

-spec go_away(error_code(), #connection_state{}) -> {next_state, closing, #connection_state{}}.
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
    {next_state, closing, State}.
