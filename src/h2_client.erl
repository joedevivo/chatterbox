-module(h2_client).
-include("http2.hrl").

%% Today's the day! We need to turn this gen_server into a gen_statem
%% which means this is going to look a lot like the "opposite of
%% http2_connection". This is the way to take advantage of the
%% abstraction of http2_socket. Still, the client API is way more
%% important than the server API so we're going to have to work
%% backwards from that API to get it right

%% {request, Headers, Data}
%% {request, [Frames]}
%% A frame that is too big should know how to break itself up.
%% That might mean into Continutations

%% API
-export([
         start_link/0,
         start_link/2,
         start_link/3,
         start_link/4,
         start_link/5,
         start/4,
         start/5,
         start_ssl_upgrade_link/4,
         stop/1,
         send_request/3,
         send_ping/1,
         sync_request/3,
         get_response/2
        ]).


%% this is gonna get weird. start_link/* is going to call
%% http2_socket's start_link function, which will handle opening the
%% socket and sending the HTTP/2 Preface over the wire. Once that's
%% working, it's going to call gen_statem:start_link(http2c, [SocketPid],
%% []) which will then use our init/1 callback. You can't actually
%% start this gen_statem with this API. That's intentional, it will
%% eventually get started if things go right. If they don't, you
%% wouldn't want one of these anyway.

%% No arg version uses a bunch of defaults, which will have to be
%% reviewed if/when this module is refactored into it's own library.
-spec start_link() -> {ok, pid()} | ignore | {error, any()}.
start_link() ->
    %% Defaults for local server, not sure these defaults are
    %% "sensible" if this module is removed from this repo

    {ok, Port} = application:get_env(chatterbox, port),
    {ok, SSLEnabled} = application:get_env(chatterbox, ssl),
    case SSLEnabled of
        true ->
            start_link(https, "localhost", Port);
        false ->
            start_link(http, "localhost", Port)
    end.

%% Start up with scheme and hostname only, default to standard ports
%% and options
-spec start_link(http | https,
                 string()) ->
                        {ok, pid()}
                      | ignore
                      | {error, term()}.
start_link(http, Host) ->
    start_link(http, Host, 80);
start_link(https,Host) ->
    start_link(https, Host, 443).

%% Start up with a specific port, or specific SSL options, but not
%% both.
-spec start_link(http | https,
                 string(),
                 non_neg_integer() | [ssl:ssl_option()]) ->
                        {ok, pid()}
                      | ignore
                      | {error, term()}.
start_link(http, Host, Port)
  when is_integer(Port) ->
    start_link(http, Host, Port, []);
start_link(https, Host, Port)
  when is_integer(Port) ->
    {ok, SSLOptions} = application:get_env(chatterbox, ssl_options),
    DefaultSSLOptions = [
                         {client_preferred_next_protocols, {client, [<<"h2">>]}}|
                         SSLOptions
                        ],
    start_link(https, Host, Port, DefaultSSLOptions);
start_link(https, Host, SSLOptions)
  when is_list(SSLOptions) ->
    start_link(https, Host, 443, SSLOptions).


%% Here's your all access client starter. MAXIMUM TUNABLES! Scheme,
%% Hostname, Port and SSLOptions. All of the start_link/* calls come
%% through here eventually, so this is where we turn 'http' and
%% 'https' into 'gen_tcp' and 'ssl' for erlang module function calls
%% later.
-spec start_link(http | https,
                 string(),
                 non_neg_integer(),
                 [ssl:ssl_option()]) ->
                        {ok, pid()}
                      | ignore
                      | {error, term()}.
start_link(Transport, Host, Port, SSLOptions) ->
    start_link(Transport, Host, Port, SSLOptions, #{}).

start_link(Transport, Host, Port, SSLOptions, ConnectionSettings) ->
    NewT = case Transport of
               http -> gen_tcp;
               https -> ssl
           end,
    h2_connection:start_client_link(NewT, Host, Port, SSLOptions, chatterbox:settings(client), ConnectionSettings).

-spec start(http | https,
                 string(),
                 non_neg_integer(),
                 [ssl:ssl_option()]) ->
                        {ok, pid()}
                      | ignore
                      | {error, term()}.
start(Transport, Host, Port, SSLOptions) ->
    NewT = case Transport of
               http -> gen_tcp;
               https -> ssl
           end,
    h2_connection:start_client(NewT, Host, Port, SSLOptions, chatterbox:settings(client), #{}).

-spec start(http | https,
            string(),
            non_neg_integer(),
            [ssl:ssl_option()],
            map()) ->
          {ok, pid()}
              | ignore
              | {error, term()}.
start(Transport, Host, Port, SSLOptions, ConnectionSettings) ->
    NewT = case Transport of
               http -> gen_tcp;
               https -> ssl
           end,
    h2_connection:start_client(NewT, Host, Port, SSLOptions, chatterbox:settings(client), ConnectionSettings).

start_ssl_upgrade_link(Host, Port, InitialMessage, SSLOptions) ->
    h2_connection:start_ssl_upgrade_link(Host, Port, InitialMessage, SSLOptions, chatterbox:settings(client), #{}).

-spec stop(pid()) -> ok.
stop(Pid) ->
    h2_connection:stop(Pid).

-spec sync_request(CliPid, Headers, Body) -> Result when
      CliPid :: pid(), Headers :: hpack:headers(), Body :: binary(),
      Result :: {ok, {hpack:headers(), iodata()}}
                 | {error, error_code() | timeout}.
sync_request(CliPid, Headers, Body) ->
    case send_request(CliPid, Headers, Body) of
        {ok, StreamId} ->
            receive
                {'END_STREAM', StreamId} ->
                    h2_connection:get_response(CliPid, StreamId)
            after 5000 ->
                      {error, timeout}
            end;
        Error ->
            Error
    end.

-spec send_request(CliPid, Headers, Body) -> Result when
      CliPid :: pid(), Headers :: hpack:headers(), Body :: binary(),
      Result :: {ok, stream_id()} | {error, error_code()}.
send_request(CliPid, Headers, Body) ->
    case h2_connection:new_stream(CliPid) of
        {error, _Code} = Err ->
            Err;
        {StreamId, _} ->
            h2_connection:send_headers(CliPid, StreamId, Headers),
            h2_connection:send_body(CliPid, StreamId, Body),
            {ok, StreamId}
    end.

send_ping(CliPid) ->
    h2_connection:send_ping(CliPid).

-spec get_response(pid(), stream_id()) ->
                          {ok, {hpack:headers(), iodata(), hpack:headers()}}
                           | not_ready
                           | {error, term()}.
get_response(CliPid, StreamId) ->
    h2_connection:get_response(CliPid, StreamId).
