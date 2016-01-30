-module(client_server_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     complex_request
    ].

init_per_suite(Config) ->
    %% We'll start up a chatterbox server once, with this data_dir.
    NewConfig = [{www_root, data_dir}|Config],
    chatterbox_test_buddy:start(NewConfig).

init_per_testcase(_, Config) ->
    lager_common_test_backend:bounce(debug),
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
         {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, StreamId} = http2_client:send_request(Client, RequestHeaders, <<>>),

    %% That's it, the request is sent.
    timer:sleep(1000),

    {ok, {ResponseHeaders, ResponseBody}} = http2_client:get_response(Client, StreamId),

    cthr:pal("Response Headers: ~p", [ResponseHeaders]),
    cthr:pal("Response Body: ~p", [ResponseBody]),

    ok.
