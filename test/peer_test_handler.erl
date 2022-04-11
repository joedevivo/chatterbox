-module(peer_test_handler).

-include_lib("chatterbox/include/http2.hrl").

-behaviour(h2_stream).

-export([
         init/3,
         on_receive_headers/2,
         on_send_push_promise/2,
         on_receive_data/2,
         on_end_stream/1
        ]).

-record(state, {conn_pid :: pid(),
                stream_id :: stream_id(),
                peer = undefined :: undefined | {inet:ip_address(),
                                                 inet:port_number()}
               }).

-spec init(pid(), stream_id(), list()) -> {ok, any()}.
init(ConnPid, StreamId, _Opts) ->
    {ok, #state{conn_pid=ConnPid,
                stream_id=StreamId}}.

-spec on_receive_headers(
            Headers :: hpack:headers(),
            CallbackState :: any()) -> {ok, NewState :: any()}.
on_receive_headers(_Headers, State=#state{conn_pid=ConnPid}) ->
    {ok, Peer} = h2_connection:get_peer(ConnPid),
    {ok, State#state{peer=Peer}}.

-spec on_send_push_promise(
            Headers :: hpack:headers(),
            CallbackState :: any()) -> {ok, NewState :: any()}.
on_send_push_promise(_Headers, State) -> {ok, State}.

-spec on_receive_data(
            iodata(),
            CallbackState :: any())-> {ok, NewState :: any()}.
on_receive_data(_Data, State) -> {ok, State}.

-spec on_end_stream(
            CallbackState :: any()) ->
    {ok, NewState :: any()}.
on_end_stream(State=#state{conn_pid=ConnPid,
                                   stream_id=StreamId,
                                   peer={Address, Port}}) ->
    Body = list_to_binary(io_lib:format("Address: ~p, Port: ~p", [Address, Port])),
    ResponseHeaders = [
                       {<<":status">>,<<"200">>}
                      ],
    h2_connection:send_headers(ConnPid, StreamId, ResponseHeaders),
    h2_connection:send_body(ConnPid, StreamId, Body),
    {ok, State}.
