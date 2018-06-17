-module(server_connection_receive_window).

-behaviour(h2_stream).

-export([
         init/3,
         on_receive_headers/2,
         on_send_push_promise/2,
         on_receive_data/2,
         on_end_stream/1
        ]).

-record(cb_static, {
        req_headers=[]
          }).

init(_ConnPid, _StreamId, _Opts) ->
    %% You need to pull settings here from application:env or something
    {ok, #cb_static{}}.

on_receive_headers(Headers, State) ->
    h2_stream:send_window_update(65535),
    ct:pal("on_receive_headers(~p, ~p)", [Headers, State]),
    {ok, State#cb_static{req_headers=Headers}}.

on_send_push_promise(Headers, State) ->
    ct:pal("on_send_push_promise(~p, ~p)", [Headers, State]),
    {ok, State#cb_static{req_headers=Headers}}.

on_receive_data(Bin, State)->
    ct:pal("on_receive_data(~p, ~p)", [Bin, State]),
    {ok, State}.

on_end_stream(State) ->
    ct:pal("on_end_stream(~p)", [State]),
    {ok, State}.
