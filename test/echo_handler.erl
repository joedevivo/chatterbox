-module(echo_handler).

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
                stream_id :: stream_id(),
                buffer = <<>> :: binary()
               }).

-spec init(pid(), stream_id()) -> {ok, any()}.
init(ConnPid, StreamId) -> {ok, #state{conn_pid=ConnPid,
                                       stream_id=StreamId}}.

-spec on_receive_request_headers(
            Headers :: hpack:headers(),
            CallbackState :: any()) -> {ok, NewState :: any()}.
on_receive_request_headers(_Headers, State) -> {ok, State}.

-spec on_send_push_promise(
            Headers :: hpack:headers(),
            CallbackState :: any()) -> {ok, NewState :: any()}.
on_send_push_promise(_Headers, State) -> {ok, State}.

-spec on_receive_request_data(
            iodata(),
            CallbackState :: any())-> {ok, NewState :: any()}.
on_receive_request_data(Data, State=#state{buffer=Buffer}) ->
    {ok, State#state{buffer = <<Buffer/binary, Data/binary>>}}.

-spec on_request_end_stream(
            CallbackState :: any()) ->
    {ok, NewState :: any()}.
on_request_end_stream(State=#state{conn_pid=ConnPid,
                                   stream_id=StreamId,
                                   buffer=Buffer}) ->
    ResponseHeaders = [
                       {<<":status">>,<<"200">>}
                      ],
    http2_connection:send_headers(ConnPid, StreamId, ResponseHeaders),
    http2_connection:send_body(ConnPid, StreamId, Buffer),
    {ok, State}.

