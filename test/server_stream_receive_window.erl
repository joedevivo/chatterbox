-module(server_stream_receive_window).

-behaviour(http2_stream).

-export([
         init/0,
         on_receive_request_headers/2,
         on_send_push_promise/2,
         on_receive_request_data/2,
         on_request_end_stream/3
        ]).

-record(cb_static, {
        req_headers=[]
          }).

init() ->
    %% You need to pull settings here from application:env or something
    {ok, #cb_static{}}.

on_receive_request_headers(Headers, State) ->
    http2_stream:send_connection_window_update(65535),
    lager:info("on_receive_request_headers(~p, ~p)", [Headers, State]),
    {ok, State#cb_static{req_headers=Headers}}.

on_send_push_promise(Headers, State) ->
    lager:info("on_send_push_promise(~p, ~p)", [Headers, State]),
    {ok, State#cb_static{req_headers=Headers}}.

on_receive_request_data(Bin, State)->
    lager:info("on_receive_request_data(~p, ~p)", [Bin, State]),
    {ok, State}.

on_request_end_stream(_StreamId, _ConnPid, State) ->
    lager:info("on_request_end_stream(~p)", [State]),
    {ok, State}.
