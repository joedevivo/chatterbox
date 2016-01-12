-module(starting_SUITE).

%%-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [identifies_protocol].

identifies_protocol(Config) ->
    chatterbox_test_buddy:start([{ssl, true}|Config]),

    {ok, Port} = application:get_env(chatterbox, port),
    ClientOptions = [
               binary,
               {packet, raw},
               {active, false}
              ],
    {ok, SSLOptions} = application:get_env(chatterbox, ssl_options),
    Options =  ClientOptions ++ SSLOptions ++ [{client_preferred_next_protocols, {client, [<<"h2">>]}}],

    {ok, Socket} = ssl:connect("localhost", Port, Options),
    ct:pal("Socket to me: ~p", [Socket]),

    try ssl:negotiated_protocol(Socket) of
         {ok, NextProtocol} ->
            ct:pal("NextProtocol: ~p", [NextProtocol]),
            <<"h2">> = NextProtocol,
            ?assertEqual(<<"h2">>, NextProtocol)
    catch
        E:M ->
            ct:pal("~p:~p", [E,M])
    end,
    timer:sleep(1000),
    ok.

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.
