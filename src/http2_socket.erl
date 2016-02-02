-module(http2_socket).

-include("http2_socket.hrl").

-behavior(gen_server).
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2
        ]).

%% There needs to be two behaviors here for starting the socket
%% gen_server. The first is for starting a server socket, which is a
%% listener socket. It needs to

-record(h2_listening_state, {
          ssl_options   :: [ssl:ssloption()],
          listen_socket :: ssl:sslsocket() | gen_tcp:socket(),
          transport     :: gen_tcp | ssl,
          listen_ref    :: non_neg_integer(),
          server_module = http2_connection :: module(),
          acceptor_callback = fun chatterbox_sup:start_socket/0 :: fun()
         }).

-export([
         start_client_link/4,
         start_server_link/3,
         send/2,
         close/1,
         get_http2_pid/1
        ]).

%% Public API
start_client_link(Transport, Host, Port, SSLOptions) ->
    gen_server:start_link(?MODULE, {client, Transport, Host, Port, SSLOptions}, []).

start_server_link(Transport, ListenSocket, SSLOptions) ->
    gen_server:start_link(?MODULE, {server, Transport, ListenSocket, SSLOptions}, []).

-spec send(pid(), frame()|iodata()) -> ok.
send(Pid, Frame) ->
    gen_server:cast(Pid, {send, Frame}).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:cast(Pid, close).

-spec get_http2_pid(pid()) -> pid().
get_http2_pid(Pid) ->
    gen_server:call(Pid, pid).


%% gen_server callbacks
-spec init( {client, gen_tcp | ssl, string(), non_neg_integer(), [ssl:ssloption()]}
          | {server, gen_tcp | ssl, ssl:sslsocket() | gen_tcp:socket(), [ssl:ssloption()]}) ->
                  {ok, #http2_socket_state{} | #h2_listening_state{}}
                | {ok, #http2_socket_state{} | #h2_listening_state{}, timeout()}
                | ignore
                | {stop, any()}.
init({server, Transport, ListenSocket, SSLOptions}) ->
    %% prim_inet:async_accept is dope. It says just hang out here and
    %% wait for a message that a client has connected. That message
    %% looks like:
    %% {inet_async, ListenSocket, Ref, {ok, ClientSocket}}
    {ok, Ref} = prim_inet:async_accept(ListenSocket, -1),
    {ok, #h2_listening_state{
            ssl_options = SSLOptions,
            listen_socket = ListenSocket,
            listen_ref = Ref,
            transport = Transport
           }};

init({client, Transport, Host, Port, SSLOptions}) ->
    ClientSocketOptions = [
                           binary,
                           {packet, raw},
                           {active, once}
                          ],
    Options = case Transport of
        ssl ->
            [{client_preferred_next_protocols, {client, [<<"h2">>]}}|ClientSocketOptions ++ SSLOptions];
        gen_tcp ->
            ClientSocketOptions
    end,
    {ok, Socket} = Transport:connect(Host, Port, Options),
    Transport:send(Socket, <<?PREFACE>>),

    %% Q: Do we want to handle the begining of the settings handshake
    %% here?  Right now I'm thinking no? But it's a real interesting
    %% question and I already changed my mind and back again. The real
    %% question is, what is the point of this server? Are we trying to
    %% make sure we have an established HTTP/2 connection and pass
    %% everything off to a server or client at that point *OR* are we
    %% just trying to get into a state where we're reading frames off
    %% the wire? It's the second thing. What we want is to be able to
    %% write servers and clients in terms of HTTP/2 frames.

    {ok, CliPid} = http2_connection:start(self(), client),

    {ok, #http2_socket_state{
            type = client,
            socket = {Transport, Socket},
            http2_pid = CliPid
           }}.

handle_call(pid, _From, #http2_socket_state{http2_pid=Pid}=State) ->
    {reply, Pid, State};
handle_call(Msg, _From, State) ->
    lager:warning("http2_socket:handle_call should never happen: ~p", [Msg]),
    {noreply, State}.
handle_cast(close,
            #http2_socket_state{
               socket={Transport,Socket}
              }=State) ->
    Transport:close(Socket),
    {stop, normal, State};
handle_cast({send, Binary}, State)
  when is_binary(Binary) ->
    socksend(Binary, State);
handle_cast({send, BinList}, State)
  when is_list(BinList) ->
    socksend(BinList, State);
handle_cast({send, Frame}, State) ->
    Binary = http2_frame:to_binary(Frame),
    socksend(Binary, State).

socksend(Binary,
         #http2_socket_state{
            socket={Transport, Socket}
           }=State) ->
    case Transport:send(Socket, Binary) of
        ok ->
            {noreply, State};
        {error, Reason} ->
            lager:info("Socksend error: ~p", [Reason]),
            {stop, Reason, State}
    end.

%% This handle info clause pattern matches an inet_async message and a
%% server with a listening state. If neither is true, we don't want
%% this
handle_info({inet_async, ListenSocket, Ref, {ok, ClientSocket}},
            #h2_listening_state{
               listen_socket = ListenSocket,
               listen_ref = Ref,
               transport = Transport,
               ssl_options = SSLOptions,
               server_module = ServerMod,
               acceptor_callback = AcceptorCallback
              }=State) ->
    inet_db:register_socket(ClientSocket, inet_tcp),
    Socket = case Transport of
        gen_tcp ->
            ClientSocket;
        ssl ->
            {ok, AcceptSocket} = ssl:ssl_accept(ClientSocket, SSLOptions),
            {ok, _Upgrayedd} = ssl:negotiated_protocol(AcceptSocket),
            AcceptSocket
    end,

    %% Pass self to server module's start link. The socket negotiation
    %% all happens here, so all we need is a place to send messages
    {ok, ServerPid} = ServerMod:start_link(self(), server),

    %% We should read the PREFACE

    %% TODO: There is no accounting here for if this is not an HTTP/2
    %% connection. This doesn't matter for https, because ALPN, but
    %% for plain it probably does.

    case Transport:recv(Socket, length(?PREFACE), 5000) of
        {ok, <<?PREFACE>>} ->
            AcceptorCallback(),
            active_once(Transport, Socket),
            {noreply, #http2_socket_state{
                    type = server,
                    socket = {Transport, Socket},
                    http2_pid = ServerPid
                   }};
        BadPreface ->
            lager:debug("Bad Preface: ~p", [BadPreface]),
            %% TODO: GoAway Frame?
            {stop, "Bad Preface", State}
    end;
%% {tcp, Socket, Data}
handle_info({tcp, Socket, Data},
            #http2_socket_state{
               socket={gen_tcp,Socket}
              }=State) ->
    handle_socket_data(Data, State);
%% {ssl, Socket, Data}
handle_info({ssl, Socket, Data},
            #http2_socket_state{
               socket={ssl,Socket}
              }=State) ->
    handle_socket_data(Data, State);
%% {tcp_passive, Socket}
handle_info({tcp_passive, Socket},
            #http2_socket_state{
               socket={gen_tcp, Socket}
              }=State) ->
    handle_socket_passive(State);
%% {tcp_closed, Socket}
handle_info({tcp_closed, Socket},
           #http2_socket_state{
              socket={gen_tcp, Socket}
             }=State) ->
    handle_socket_closed(State);
%% {ssl_closed, Socket}
handle_info({ssl_closed, Socket},
            #http2_socket_state{
               socket={ssl, Socket}
              }=State) ->
    handle_socket_closed(State);
%% {tcp_error, Socket, Reason}
handle_info({tcp_error, Socket, Reason},
            #http2_socket_state{
               socket={gen_tcp,Socket}
              }=State) ->
    handle_socket_error(Reason, State);
%% {ssl_error, Socket, Reason}
handle_info({ssl_error, Socket, Reason},
            #http2_socket_state{
               socket={ssl,Socket}
              }=State) ->
    handle_socket_error(Reason, State).

%% Incoming data is a series of frames. With a passive socket we can just:
%% 1. read(9)
%% 2. turn that 9 into an http2 frame header
%% 3. use that header's length field L
%% 4. read(L), now we have a frame
%% 5. do something with it
%% 6. goto 1

%% Things will be different with an {active, true} socket, and also
%% different again with an {active, once} socket

%% with {active, true}, we'd have to maintain some kind of input queue
%% because it will be very likely that Data is not neatly just a frame

%% with {active, once}, we'd probably be in a situation where Data
%% starts with a frame header. But it's possible that we're here with
%% a partial frame left over from the last active stream

%% We're going to go with the {active, once} approach, because it
%% won't block the gen_server on Transport:read(L), but it will wake
%% up and do something every time Data comes in.

handle_socket_data(<<>>, #http2_socket_state{
                            socket={Transport,Socket}
                           }=State) ->
    active_once(Transport, Socket),
    {noreply, State};
%% This is the first data frame! It means we were started by a more
%% generic acceptor pool, like ranch TODO: this technically will match
%% on this binary if it ever sees it again, not just on connect. that
%% shouldn't happen, but there could be a way to keep track of it in
%% #state
handle_socket_data(<<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", Rem/binary>>,
                   #http2_socket_state{
                      %socket={Transport,Socket}
                     }=State) ->
    handle_socket_data(Rem, State);
handle_socket_data(Data,
                   #http2_socket_state{
                      socket={Transport, Socket},
                      buffer=Buffer,
                      http2_pid=ServerPid
                     }=State) ->

    lager:debug("Data: ~p", [Data]),

    More = case Transport:recv(Socket, 0, 1) of %% fail fast!
        {ok, Rest} ->
            Rest;
        %% It's not really an error, it's what we want
        {error, timeout} ->
            <<>>
    end,

    %% What is buffer?
    %% empty - nothing, yay
    %% {frame, frame_header(), binary()} - Frame Header processed, Payload not big enough
    %% {binary, binary()} - If we're here, it must mean that Bin was too small to even be a header
    ToParse = case Buffer of
        empty ->
            <<Data/binary,More/binary>>;
        {frame, FHeader, BufferBin} ->
            {FHeader, <<BufferBin/binary,Data/binary,More/binary>>};
        {binary, BufferBin} ->
            <<BufferBin/binary,Data/binary,More/binary>>
    end,
    %% Now that the buffer has been merged, it's best to make sure any
    %% further state references don't have one
    NewState = State#http2_socket_state{buffer=empty},

    case http2_frame:recv(ToParse) of
        %% We got a full frame, ship it off to the FSM
        {ok, Frame, Rem} ->
            gen_fsm:send_event(ServerPid, {frame, Frame}),
            handle_socket_data(Rem, NewState);
        %% Not enough bytes left to make a header :(
        {error, not_enough_header, Bin} ->
            {noreply, NewState#http2_socket_state{buffer={binary, Bin}}};
        %% Not enough bytes to make a payload
        {error, not_enough_payload, Header, Bin} ->
            {noreply, NewState#http2_socket_state{buffer={frame, Header, Bin}}}
    end.


handle_socket_passive(State) ->
    {noreply, State}.

handle_socket_closed(State) ->
    {noreply, State}.

handle_socket_error(_Reason, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason,
          #http2_socket_state{
             socket={Transport, Socket}
            }=State) ->
    Transport:close(Socket),
    {stop, Reason, State};
terminate(Reason, State) ->
    {stop, Reason, State}.

active_once(Transport, Socket) ->
    T = case Transport of
        ssl -> ssl;
        gen_tcp -> inet
    end,
    T:setopts(Socket, [{active, once}]).
