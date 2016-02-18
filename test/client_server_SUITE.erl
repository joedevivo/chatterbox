-module(client_server_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     complex_request,
     upgrade_tcp_connection
    ].

init_per_suite(Config) ->
    %% We'll start up a chatterbox server once, with this data_dir.
    NewConfig = [{www_root, data_dir}|Config],
    chatterbox_test_buddy:start(NewConfig).

init_per_testcase(_, Config) ->
    Config.

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

complex_request(_Config) ->
    {ok, Client} = http2_client:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, {ResponseHeaders, ResponseBody}} = http2_client:sync_request(Client, RequestHeaders, <<>>),

    cthr:pal("Response Headers: ~p", [ResponseHeaders]),
    cthr:pal("Response Body: ~p", [ResponseBody]),

    ok.

upgrade_tcp_connection(_Config) ->
    {ok, Client} = http2_client:start_ssl_upgrade_link("localhost", 8081, <<>>, []),

    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, {ResponseHeaders, ResponseBody}} = http2_client:sync_request(Client, RequestHeaders, <<>>),
    cthr:pal("Response Headers: ~p", [ResponseHeaders]),
    cthr:pal("Response Body: ~p", [ResponseBody]),
    ok.
