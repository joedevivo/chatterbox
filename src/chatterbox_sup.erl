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
    {ok, Port} = application:get_env(chatterbox, port),
    Options = [
        binary,
        {reuseaddr, true},
        {packet, raw},
        {backlog, 1024},
        {active, false}
    ],
    {ok, SSLEnabled} = application:get_env(chatterbox, ssl),
    {Transport, SSLOptions} = case SSLEnabled of
        true ->
            {ok, SSLOpts} = application:get_env(chatterbox, ssl_options),
            {ssl, SSLOpts};
        false ->
            {gen_tcp, []}
    end,

    Http2Settings = chatterbox:settings(server),

    spawn_link(fun empty_listeners/0),
    {ok, ListenSocket} = gen_tcp:listen(Port, Options),
    Restart = {simple_one_for_one, 60, 3600},
    Children = [{socket,
                {h2_connection, start_server_link, [{Transport, ListenSocket}, SSLOptions, Http2Settings]},
                temporary, 1000, worker, [h2_connection]}],
    {ok, {Restart, Children}}.

start_socket() ->
    supervisor:start_child(?MODULE, []).

empty_listeners() ->
    {ok, ConcurrentAcceptors} = application:get_env(chatterbox, concurrent_acceptors),
    [ start_socket() || _ <- lists:seq(1,ConcurrentAcceptors)].
