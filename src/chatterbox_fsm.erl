-module(chatterbox_fsm).

-behaviour(gen_fsm).

-include("http2.hrl").

-record(chatterbox_fsm_state, {
        socket :: {gen_tcp | ssl, port()},
        frame_backlog = [],
        settings_backlog = [],
        client_settings = undefined,
        server_settings = #settings{},
        next_available_stream_id = 2 :: stream_id(),
        streams = [] :: [proplists:property()]
    }).

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
         connected/2]).

start_link(Socket) ->
    gen_fsm:start_link(?MODULE, Socket, []).

init(Socket) ->
    lager:debug("Starting chatterbox_fsm"),
    gen_fsm:send_event(self(), start),
    {ok, accept, #chatterbox_fsm_state{socket=Socket}}.

%% accepting connection state:
accept(start, S = #chatterbox_fsm_state{socket={Transport,ListenSocket}}) ->
    lager:debug("chatterbox_fsm accept"),

    %% TCP Version
    %%    {ok, AcceptSocket} = Transport:accept(ListenSocket),


    %% SSL conditional stuff

    {ok, AcceptSocket} = ssl:transport_accept(ListenSocket),

    lager:info("about to accept"),
    Accept = ssl:ssl_accept(AcceptSocket),

    lager:info("accepted ~p", [Accept]),
    lager:info("about to negotiate"),
    {ok, Upgrayedd} = ssl:negotiated_next_protocol(AcceptSocket),
    lager:info("Upgrayedd ~p", [Upgrayedd]),

    ssl:setopts(AcceptSocket, [{active, once}]),

    %% Start up a listening socket to take the place of this socket,
    %% that's no longer listening
    chatterbox_sup:start_socket(),

    {next_state, settings_handshake, S#chatterbox_fsm_state{socket={Transport,AcceptSocket}}}.

%% From Section 6.5 of the HTTP/2 Specification
%% A SETTINGS frame MUST be sent by both endpoints at the start of a
%% connection, and MAY be sent at any other time by either endpoint
%% over the lifetime of the connection. Implementations MUST support
%% all of the parameters defined by this specification.
settings_handshake({start_frame, Bin}, S = #chatterbox_fsm_state{
                                       socket=Socket,
                                       server_settings=ServerSettings
                                      }) ->
    %% We just triggered this from the handle info of the HTTP/2 preamble

    %% It's possible we got more. Thanks, Nagle.
    NewState = case Bin of
        <<>> ->
            S;
        _ ->
            OtherFrames = http2_frame:from_binary(Bin),
            {SettingsBacklog, FB} = lists:partition(
                fun({X,_}) -> X#frame_header.type =:= ?SETTINGS end,
                OtherFrames),
            S#chatterbox_fsm_state{frame_backlog=FB, settings_backlog=SettingsBacklog}
    end,

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

    settings_handshake_loop(NewState, {false, false}).

settings_handshake_loop(State=#chatterbox_fsm_state{frame_backlog=FB}, {true, true}) ->
    gen_fsm:send_event(self(), backlog),
    {next_state, connected, State#chatterbox_fsm_state{frame_backlog=lists:reverse(FB)}};
settings_handshake_loop(State = #chatterbox_fsm_state{
                                   settings_backlog=[{H,P}|T]
                                  },
                        Acc) ->
    lager:debug("[settings_handshake] Backlogged Frame"),
    settings_handshake_loop({H#frame_header.type, ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK)}, {H, P}, Acc, State#chatterbox_fsm_state{settings_backlog=T});
settings_handshake_loop(State = #chatterbox_fsm_state{
                                   socket=Socket,
                                   settings_backlog=[]
                                  },
                        Acc) ->
    lager:debug("[settings_handshake] Incoming Frame"),
    {H, Payload} = http2_frame:read(Socket),
    settings_handshake_loop({H#frame_header.type,?IS_FLAG(H#frame_header.flags, ?FLAG_ACK)}, {H, Payload}, Acc, State).

settings_handshake_loop({?SETTINGS,false},{_Header,ClientSettings}, {ReceivedAck,false}, State = #chatterbox_fsm_state{socket=S}) ->
    lager:debug("[settings_handshake] got client_settings: ~p", [http2_frame_settings:format(ClientSettings)]),
    http2_frame_settings:ack(S),
    settings_handshake_loop(State#chatterbox_fsm_state{client_settings=ClientSettings}, {ReceivedAck,true});
settings_handshake_loop({?SETTINGS,true},{_,_},{false,ReceivedClientSettings},State) ->
    lager:debug("[settings_handshake] got server_settings ack"),
    settings_handshake_loop(State,{true,ReceivedClientSettings});
settings_handshake_loop(_,FrameToBacklog,Acc,State=#chatterbox_fsm_state{frame_backlog=FB}) ->
    lager:debug("[settings_handshake] got rando frame"),
    settings_handshake_loop(State#chatterbox_fsm_state{frame_backlog=[FrameToBacklog|FB]}, Acc).

connected(backlog, S = #chatterbox_fsm_state{frame_backlog=[F|T]}) ->
    Response = route_frame(F, S#chatterbox_fsm_state{frame_backlog=T}),
    gen_fsm:send_event(self(), backlog),

    Response;
connected(backlog, S = #chatterbox_fsm_state{frame_backlog=[]}) ->
    gen_fsm:send_event(self(), start_frame),
    {next_state, connected, S};
connected(start_frame, S = #chatterbox_fsm_state{socket=Socket}) ->
    lager:debug("[connected] Incoming Frame"),
    {_Header, _Payload} = Frame = http2_frame:read(Socket),

    Response = route_frame(Frame, S),
    %% After frame is routed, let the FSM know we're ready for another
    %% TODO there could be a race condition in here where the next call to start_frame uses a different State then the one we're returning here
    %% e.g. the routed frame creates a new stream which is not yet in the State. Test it once those are implemented ahahaahahaha
    gen_fsm:send_event(self(), start_frame),
    Response.

%% Maybe use something like this for readability later
%% -define(SOCKET_PM, #chatterbox_fsm_state{socket=Socket}).

-spec route_frame(frame(), #chatterbox_fsm_state{}) ->
    {next_state, connected, #chatterbox_fsm_state{}}.
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?DATA ->
    lager:debug("Received DATA Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this DATA away"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=StreamId}, Payload}, S = #chatterbox_fsm_state{socket=Socket,streams=Streams})
    when H#frame_header.type == ?HEADERS ->
    lager:debug("Received HEADERS Frame for Stream ~p", [StreamId]),
    %% Spin up http2_stream fsm
    {ok, StreamPid} = http2_stream:start_link(self(), Socket,  StreamId),

    %% send it this headers frame which should transition it into the open state
    gen_fsm:send_event(StreamPid, {recv, {H, Payload}}),
    %% Add that pid to the set of streams in our state
    {next_state, connected, S#chatterbox_fsm_state{streams=[{StreamId, StreamPid}|Streams]}};
route_frame({H, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?PRIORITY,
         H#frame_header.stream_id == 16#0 ->
    lager:debug("Received PRIORITY Frame"),
    lager:error("Chatterbox doesn't support PRIORITY"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?RST_STREAM ->
    lager:debug("Received RST_STREAM Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this RST_STREAM away"),
    {next_state, connected, S};
%% Got a settings frame, need to ACK
route_frame({H, Payload}, S = #chatterbox_fsm_state{socket=Socket})
    when H#frame_header.type == ?SETTINGS,
         ?NOT_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received SETTINGS"),
    http2_frame_settings:ack(Socket),
    {next_state, connected, S#chatterbox_fsm_state{client_settings=Payload}};
%% Got settings ACK
route_frame({H, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?SETTINGS,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received SETTINGS ACK"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?PUSH_PROMISE ->
    lager:debug("Received PUSH_PROMISE Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this PUSH_PROMISE away"),
    {next_state, connected, S};
route_frame({H, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?PING,
         ?NOT_FLAG(#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received PING"),
    {next_state, connected, S};
route_frame({H, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?PING,
         ?IS_FLAG(H#frame_header.flags, ?FLAG_ACK) ->
    lager:debug("Received PING ACK"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?GOAWAY ->
    lager:debug("Received GOAWAY Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this GOAWAY away"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?WINDOW_UPDATE ->
    lager:debug("Received WINDOW_UPDATE Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this WINDOW_UPDATE away"),
    {next_state, connected, S};
route_frame({H=#frame_header{stream_id=StreamId}, _Payload}, S = #chatterbox_fsm_state{socket=_Socket})
    when H#frame_header.type == ?CONTINUATION ->
    lager:debug("Received CONTINUATION Frame for Stream ~p", [StreamId]),
    lager:error("Chatterbox doesn't support streams. Throwing this CONTINUATION away"),
    {next_state, connected, S};
route_frame(_, State) ->
    %% TODO Connection Error here, since pattern matches should cover the rules
    {next_state, connected, State}.


handle_event(_E, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_E, _F, StateName, State) ->
    {next_state, StateName, State}.


handle_info({_, _Socket, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",Bin/bits>>}, _, S) ->
    lager:debug("handle_info HTTP/2 Preamble!"),
    gen_fsm:send_event(self(), {start_frame,Bin}),
    {next_state, settings_handshake, S};
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
