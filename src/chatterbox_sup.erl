-module(chatterbox_sup).

-behaviour(supervisor).

-export([
         init/1,
         start_link/0,
         start_socket/0
        ]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, Port} = application:get_env(port),
    ListenerOptions = [
        {active, once}, binary
    ],
    spawn_link(fun empty_listeners/0),
    {ok, ListenSocket} = gen_tcp:listen(Port, ListenerOptions),
    Restart = {simple_one_for_one, 60, 3600},
    Children = [{socket,
                {chatterbox_fsm, start_link, [ListenSocket]}, % pass the socket!
                temporary, 1000, worker, [chatterbox_fsm]}],
    {ok, {Restart, Children}}.

start_socket() ->
    supervisor:start_child(?MODULE, []).

empty_listeners() ->
    {ok, ConcurrentAcceptors} = application:get_env(concurrent_acceptors),
    [ start_socket() || _ <- lists:seq(1,ConcurrentAcceptors)].