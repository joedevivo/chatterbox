-module(chatterbox_fsm).

-behaviour(gen_fsm).

-include("http2.hrl").

-record(chatterbox_fsm_state, {
        socket,
        frame_backlog = [],
        client_settings = undefined,
        server_settings = #settings{}
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
accept(start, S = #chatterbox_fsm_state{socket=ListenSocket}) ->
    lager:debug("chatterbox_fsm accept"),
    {ok, AcceptSocket} = gen_tcp:accept(ListenSocket),

    %% Start up a listening socket to take the place of this socket,
    %% that's no longer listening
    chatterbox_sup:start_socket(),

    {next_state, settings_handshake, S#chatterbox_fsm_state{socket=AcceptSocket}}.

%% From Section 6.5 of the HTTP/2 Specification
%% A SETTINGS frame MUST be sent by both endpoints at the start of a
%% connection, and MAY be sent at any other time by either endpoint
%% over the lifetime of the connection. Implementations MUST support
%% all of the parameters defined by this specification.
settings_handshake(start_frame, S = #chatterbox_fsm_state{
                                       socket=Socket,
                                       frame_backlog=FB,
                                       server_settings=ServerSettings
                                      }) ->
    %% We just triggered this from the handle info of the HTTP/2 preamble

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

    settings_handshake_loop(S, {false, false}).

settings_handshake_loop(State=#chatterbox_fsm_state{frame_backlog=FB}, {true, true}) ->
    gen_fsm:send_event(self(), start_frame),
    {next_state, connected, State#chatterbox_fsm_state{frame_backlog=lists:reverse(FB)}};
settings_handshake_loop(State = #chatterbox_fsm_state{
                                   socket=Socket
                                  },
                        Acc) ->
    lager:debug("[settings_handshake] Incoming Frame"),
    {Header, Payload} = http2_frame:read(Socket),
    settings_handshake_loop({Header#header.type,Header#header.flags band 16#1}, {Header, Payload}, Acc, State).

settings_handshake_loop({?SETTINGS,0},{_Header,ClientSettings}, {ReceivedAck,false}, State = #chatterbox_fsm_state{socket=S}) ->
    lager:debug("[settings_handshake] got client_settings"),
    http2_frame_settings:ack(S),
    settings_handshake_loop(State#chatterbox_fsm_state{client_settings=ClientSettings}, {ReceivedAck,true});
settings_handshake_loop({?SETTINGS,1},{_,_},{false,ReceivedClientSettings},State) ->
    lager:debug("[settings_handshake] got server_settings ack"),
    settings_handshake_loop(State,{true,ReceivedClientSettings});
settings_handshake_loop(_,FrameToBacklog,Acc,State=#chatterbox_fsm_state{frame_backlog=FB}) ->
    lager:debug("[settings_handshake] got rando frame"),
    settings_handshake_loop(State#chatterbox_fsm_state{frame_backlog=[FrameToBacklog|FB]}, Acc).

connected(start_frame, S = #chatterbox_fsm_state{socket=Socket}) ->
    lager:debug("[connected] Incoming Frame"),
    {Header, Payload} = http2_frame:read(Socket),
    gen_fsm:send_event(self(), start_frame),

    %% Settings can still come in and be renegotiated at any time
    case {Header#header.type, Header#header.flags} of
        {?SETTINGS,0} ->
            lager:debug("got dat settings 0"),
            http2_frame_settings:send(Socket, Payload),
            {next_state, connected, S#chatterbox_fsm_state{client_settings=Payload}};
        {?SETTINGS,1} ->
            lager:debug("got dat settings 1"),
            http2_frame_settings:ack(Socket),
            {next_state, connected, S#chatterbox_fsm_state{client_settings=Payload}};
        _ ->
            {next_state, connected, S}
    end.

handle_event(_E, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_E, _F, StateName, State) ->
    {next_state, StateName, State}.


handle_info({tcp, _Socket, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>}, _, S) ->
    lager:debug("handle_info HTTP/2 Preamble!"),
    gen_fsm:send_event(self(), start_frame),
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

code_change(_OldVsn, _StateName, State, _Extra) ->
    {ok, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    lager:debug("terminate reason: ~p~n", [_Reason]).
