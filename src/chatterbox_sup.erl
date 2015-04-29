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
        binary,
        {reuseaddr, true},
        {packet, raw},
        %{nodelay, true},
        {backlog, 1024},
        %{send_timeout, 30000},
        %{send_timeout_close, true},
        %% {keepalive, true}, {reuseaddr, true} %%, {nodelay, true}, {delay_send, false}, {backlog, 1024}
        {active, false}
    ],
    {ok, SSLEnabled} = application:get_env(ssl),
    {Transport, Options} = case SSLEnabled of
        true ->
            {ok, SSLOptions} = application:get_env(ssl_options),
            {ssl, ListenerOptions ++ SSLOptions};
        false ->
            {gen_tcp, ListenerOptions}
    end,

    spawn_link(fun empty_listeners/0),
    {ok, ListenSocket} = Transport:listen(Port, Options),
    Restart = {simple_one_for_one, 60, 3600},
    Children = [{socket,
                {chatterbox_fsm, start_link, [{Transport, ListenSocket}]}, % pass the socket!
                temporary, 1000, worker, [chatterbox_fsm]}],
    {ok, {Restart, Children}}.

start_socket() ->
    supervisor:start_child(?MODULE, []).

empty_listeners() ->
    {ok, ConcurrentAcceptors} = application:get_env(concurrent_acceptors),
    [ start_socket() || _ <- lists:seq(1,ConcurrentAcceptors)].
