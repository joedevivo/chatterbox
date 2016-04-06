-module(peer_test_handler).

-include_lib("chatterbox/include/http2.hrl").

-behaviour(http2_stream).

-export([
         init/2,
         on_receive_request_headers/2,
         on_send_push_promise/2,
         on_receive_request_data/2,
         on_request_end_stream/1
        ]).

-record(state, {conn_pid :: pid(),
                stream_id :: integer(),
                peer = undefined :: undefined | {inet:ip_addres(),
                                                 inet:port_number()}
               }).

-spec init(pid(), integer()) -> {ok, any()}.
init(ConnPid, StreamId) -> {ok, #state{conn_pid=ConnPid,
                                       stream_id=StreamId}}.

-spec on_receive_request_headers(
            Headers :: hpack:headers(),
            CallbackState :: any()) -> {ok, NewState :: any()}.
on_receive_request_headers(_Headers, State=#state{conn_pid=ConnPid}) ->
    {ok, Peer} = http2_connection:get_peer(ConnPid),
    State#state{peer=Peer}.

-spec on_send_push_promise(
            Headers :: hpack:headers(),
            CallbackState :: any()) -> {ok, NewState :: any()}.
on_send_push_promise(_Headers, State) -> {ok, State}.

-spec on_receive_request_data(
            iodata(),
            CallbackState :: any())-> {ok, NewState :: any()}.
on_receive_request_data(_Data, State) -> {ok, State}.

-spec on_request_end_stream(
            CallbackState :: any()) ->
    {ok, NewState :: any()}.
on_request_end_stream(State=#state{conn_pid=ConnPid,
                                   stream_id=StreamId,
                                   peer={Address, Port}}) ->
    Body = list_to_binary(io_lib:format("Address: ~p, Port: ~p", [Address, Port])),
    ResponseHeaders = [
                       {<<":status">>,<<"200">>}
                      ],
    http2_connection:send_headers(ConnPid, StreamId, ResponseHeaders),
    http2_connection:send_body(ConnPid, StreamId, Body),
    {ok, State}.

