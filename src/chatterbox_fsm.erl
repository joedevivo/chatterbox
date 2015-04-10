-module(chatterbox_fsm).

-behaviour(gen_fsm).

-include("http2.hrl").

-record(chatterbox_fsm_state, {
        socket,
        settings = #settings{}
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

-export([accept/2, connected/2]).

start_link(Socket) ->
    gen_fsm:start_link(?MODULE, Socket, []).

init(Socket) ->
    lager:debug("Starting chatterbox_fsm"),
    gen_fsm:send_event(self(), start),
    {ok, accept, #chatterbox_fsm_state{socket=Socket}}.

%% accepting connection state
accept(start, S = #chatterbox_fsm_state{socket=ListenSocket}) ->
    lager:debug("chatterbox_fsm accept"),
    {ok, AcceptSocket} = gen_tcp:accept(ListenSocket),
    chatterbox_sup:start_socket(),
    {next_state, connecting, S#chatterbox_fsm_state{socket=AcceptSocket}}.

connected(start_frame, S = #chatterbox_fsm_state{socket=Socket}) ->
    lager:debug("Incoming Frame"),
    {Header, Payload} = http2_frame:read(Socket),
    gen_fsm:send_event(self(), start_frame),
    case {Header#header.type, Header#header.flags} of
        {?SETTINGS,<<0>>} ->
            lager:debug("got dat settings 0"),
            http2_frame_settings:ack(Socket, Payload),
            {next_state, connected, S#chatterbox_fsm_state{settings=Payload}};
        {?SETTINGS,<<1>>} ->
            lager:debug("got dat settings 1"),
            http2_frame_settings:ack(Socket),
            {next_state, connected, S#chatterbox_fsm_state{settings=Payload}};
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
    {next_state, connected, S};
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
