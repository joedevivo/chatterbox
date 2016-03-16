-module(server_stream_receive_window).

-behaviour(http2_stream).

-export([
         init/2,
         on_receive_request_headers/2,
         on_send_push_promise/2,
         on_receive_request_data/2,
         on_request_end_stream/1
        ]).

-record(cb_static, {
        req_headers=[]
          }).

init(_ConnPid, _StreamId) ->
    %% You need to pull settings here from application:env or something
    {ok, #cb_static{}}.

on_receive_request_headers(Headers, State) ->
    http2_stream:send_connection_window_update(65535),
    ct:pal("on_receive_request_headers(~p, ~p)", [Headers, State]),
    {ok, State#cb_static{req_headers=Headers}}.

on_send_push_promise(Headers, State) ->
    ct:pal("on_send_push_promise(~p, ~p)", [Headers, State]),
    {ok, State#cb_static{req_headers=Headers}}.

on_receive_request_data(_Bin, State)->
    ct:pal("on_receive_request_data(Bin!, ~p)", [State]),
    {ok, State}.

on_request_end_stream(State) ->
    ct:pal("on_request_end_stream(~p)", [State]),
    {ok, State}.
