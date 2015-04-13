%%
%%                             +--------+
%%                     send PP |        | recv PP
%%                    ,--------|  idle  |--------.
%%                   /         |        |         \
%%                  v          +--------+          v
%%           +----------+          |           +----------+
%%           |          |          | send H /  |          |
%%    ,------| reserved |          | recv H    | reserved |------.
%%    |      | (local)  |          |           | (remote) |      |
%%    |      +----------+          v           +----------+      |
%%    |          |             +--------+             |          |
%%    |          |     recv ES |        | send ES     |          |
%%    |   send H |     ,-------|  open  |-------.     | recv H   |
%%    |          |    /        |        |        \    |          |
%%    |          v   v         +--------+         v   v          |
%%    |      +----------+          |           +----------+      |
%%    |      |   half   |          |           |   half   |      |
%%    |      |  closed  |          | send R /  |  closed  |      |
%%    |      | (remote) |          | recv R    | (local)  |      |
%%    |      +----------+          |           +----------+      |
%%    |           |                |                 |           |
%%    |           | send ES /      |       recv ES / |           |
%%    |           | send R /       v        send R / |           |
%%    |           | recv R     +--------+   recv R   |           |
%%    | send R /  `----------->|        |<-----------'  send R / |
%%    | recv R                 | closed |               recv R   |
%%    `----------------------->|        |<----------------------'
%%                             +--------+
%%
%%       send:   endpoint sends this frame
%%       recv:   endpoint receives this frame
%%
%%       H:  HEADERS frame (with implied CONTINUATIONs)
%%       PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
%%       ES: END_STREAM flag
%%       R:  RST_STREAM frame


-module(http2_stream).

-behaviour(gen_fsm).

-include("http2.hrl").

-record(http2_stream_state, {
        socket = undefined :: undefined | socket(),
        connection :: pid(),
        stream_id = undefined :: undefined | integer(),
        req_headers = undefined
    }).

-export([
    start_link/3
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

%% States
-export([
    idle/2,
    open/2,
    reserved_local/2,
    reserved_remote/2,
    half_closed_local/2,
    half_closed_remote/2,
    closed/2
    ]).

%%-spec start_link(pid(), port(), stream_id()) ->
start_link(ParentConnection, Socket, StreamId) ->
    gen_fsm:start_link(?MODULE, [ParentConnection, Socket, StreamId], []).

init([ParentConnection, Socket, StreamId]) ->
    lager:debug("Starting "),
    %gen_fsm:send_event(self(), start),
    {ok, idle, #http2_stream_state{
            socket=Socket,
            connection = ParentConnection,
            stream_id = StreamId
        }}.

-spec idle({send | recv , frame()}, #http2_stream_state{}) ->
        {next_state,
         open | reserved_local | reserved_remote,
         #http2_stream_state{}} | {stop, connection_error, #http2_stream_state{}}.
idle({_, {#frame_header{type=?HEADERS,stream_id=StrId,flags=F},Payload}},
    State = #http2_stream_state{stream_id=StrId,socket=Socket})
        when ?IS_FLAG(F,?FLAG_END_HEADERS) ->
    %% Headers are done!
    lager:debug("Header Payload: ~p", [Payload]),
    Headers = hpack:decode(Payload#headers.block_fragment),
    %% TODO Process Headers
    lager:debug("Headers decoded: ~p", [Headers]),
    %% TODO: next two lines are super hard coded to prove I can respond
    http2_frame_headers:send(Socket, StrId, <<136>>),
    http2_frame_data:send(Socket, StrId, <<"hi!">>),
    {next_state, open, State#http2_stream_state{req_headers=Headers}};
idle({send, {#frame_header{type=?PUSH_PROMISE,stream_id=StrId},_}},
     State = #http2_stream_state{stream_id=StrId}) ->
    %% TODO Sent a Push Promise
    {next_state, reserved_local, State};
idle({recv, {#frame_header{type=?PUSH_PROMISE,stream_id=StrId},_}},
     State = #http2_stream_state{stream_id=StrId}) ->
    %% TODO recv'd Push Promise
    {next_state, reserved_remote, State};
idle(Msg, State) ->
    lager:error("no match!"),
    lager:debug("Frame: ~p", [Msg]),
    lager:debug("State: ~p", [State]),
    {stop, connection_error, State}.

-spec open({send | recv, frame()}, #http2_stream_state{}) ->
    {next_state,
     closed | half_closed_remote | half_closed_local,
     #http2_stream_state{}}.
open({_, {#frame_header{type=?RST_STREAM}}}, State) ->
    {next_state, closed, State};
open({send, {#frame_header{flags=F},_}}, State) ->
    NextState = case F band ?FLAG_END_STREAM of
        1 ->
            half_closed_local;
        0 ->
            open
    end,
    {next_state, NextState, State};
open({recv, {#frame_header{flags=F},_}}, State) ->
    NextState = case F band 16#1 of
        1 ->
            half_closed_remote;
        0 ->
            open
    end,
    {next_state, NextState, State}.

-spec reserved_local({send | recv, frame()}, #http2_stream_state{}) ->
    {next_state,
     half_closed_remote | closed,
     #http2_stream_state{}}.
reserved_local(_, State) ->
    {next_state, half_closed_remote, State}.

-spec reserved_remote({send | recv, frame()}, #http2_stream_state{}) ->
    {next_state,
     half_closed_local | closed,
     #http2_stream_state{}}.
reserved_remote(_, State) ->
    {next_state, half_closed_local, State}.

-spec half_closed_local({send | recv, frame()}, #http2_stream_state{}) ->
    {next_state,
     closed,
     #http2_stream_state{}}.
half_closed_local(_, State) ->
    {next_state, closed, State}.

-spec half_closed_remote({send | recv, frame()}, #http2_stream_state{}) ->
    {next_state,
     closed,
     #http2_stream_state{}}.
half_closed_remote(_, State) ->
    {next_state, closed, State}.

-spec closed({send | recv, frame()}, #http2_stream_state{}) ->
    {next_state,
     closed,
     #http2_stream_state{}} |
    {stop,
     _, #http2_stream_state{}}.
closed({_, {#frame_header{type=?PRIORITY},_}}, State) ->
    %% Right now we ignore PRIORITY
    {next_state, closed, State};
closed(_, State) ->
    {stop, stream_closed, State}.

handle_event(_E, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_E, _F, StateName, State) ->
    {next_state, StateName, State}.

handle_info(E, StateName, S) ->
    lager:debug("unexpected [~p]: ~p~n", [StateName, E]),
    {next_state, StateName , S}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    lager:debug("terminate reason: ~p~n", [_Reason]).
