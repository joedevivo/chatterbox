-module(http2c).

-behaviour(gen_server).

-include("http2.hrl").

%% gen_server
%% start on a socket.
%% send the preamble
%% send/recv settings
%% now the gen_server has a connection

%% {request, Headers, Data}
%% {request, [Frames]}
%% A frame that is too big should know how to break itself up.
%% That might mean into Continutations

%% API
-export([
         start_link/0,
         send_binary/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(http2c_state, {
          socket :: {gen_tcp | ssl, port()},
          client_settings = #settings{},
          server_settings = undefined,
          decode_context = hpack:new_decode_context() :: hpack:decode_context(),
          encode_context = hpack:new_encode_context() :: hpack:encode_context(),
          incoming_frames = [] :: [frame()]
}).

%% Starts a server. Should probably take args eventually
-spec start_link() -> {ok, pid()} | ignore | {error, any()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

send_binary(Pid, Binary) ->
    gen_server:cast(Pid, {send_bin, Binary}).

%% Three API levels:
%% 1: lowest: Send a frame or set of frames
%% 2: middle: Here's some hastily constucted frames, do some setup of frame header flags.
%% 3: highest: a semantic http request: here are

%% gen_server callbacks

%% Initializes the server
-spec init(list()) -> {ok, #http2c_state{}} |
                      {ok, #http2c_state{}, timeout()} |
                      ignore |
                      {stop, any()}.
init([]) ->
    %% TODO: Open a socket
    Host = "localhost",
    {ok, Port} = application:get_env(chatterbox, port),
    ClientOptions = [
               binary,
               {packet, raw},
               {active, false}
              ],
    {ok, SSLEnabled} = application:get_env(chatterbox, ssl),
    {Transport, Options} = case SSLEnabled of
        true ->
            {ok, SSLOptions} = application:get_env(chatterbox, ssl_options),
            {ssl, ClientOptions ++ SSLOptions ++ [{client_preferred_next_protocols, {client, [<<"h2">>]}}]};
        false ->
            {gen_tcp, ClientOptions}
    end,
    lager:debug("Transport: ~p", [Transport]),
    {ok, Socket} = Transport:connect(Host, Port, Options),
    %% TODO: Send the preamble
    ssl:send(Socket, <<?PREAMBLE>>),
    %% TODO: Settings Handshake

    {_SSH, ServerSettings}  = http2_frame:read({Transport, Socket}),
    http2_frame_settings:ack({Transport, Socket}),

    ClientSettings = #settings{},
    http2_frame_settings:send({Transport, Socket}, ClientSettings),
    {AH, _Ack} = http2_frame:read({Transport, Socket}),
    Ack =  ?IS_FLAG(AH#frame_header.flags, ?FLAG_ACK),
    lager:debug("Ack: ~p", [Ack]),

    Transport:setopts(Socket, [{active, true}]),

    {ok, #http2c_state{
            socket = {Transport, Socket},
            client_settings = ClientSettings,
            server_settings = ServerSettings
           }}.

%% Handling call messages
-spec handle_call(term(), pid(), #http2c_state{}) ->
                         {reply, any(), #http2c_state{}} |
                         {reply, any(), #http2c_state{}, timeout()} |
                         {noreply, #http2c_state{}} |
                         {noreply, #http2c_state{}, timeout()} |
                         {stop, any(), any(), #http2c_state{}} |
                         {stop, any(), #http2c_state{}}.
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% Handling cast messages
-spec handle_cast(any(), #http2c_state{}) ->
                         {noreply, #http2c_state{}} |
                         {noreply, #http2c_state{}, timeout()} |
                         {stop, any(), #http2c_state{}}.
handle_cast({send_bin, Bin}, #http2c_state{socket={Transport, Socket}}=State) ->
    lager:debug("Sending ~p", [Bin]),
    Transport:send(Socket, Bin),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% Handling all non call/cast messages
-spec handle_info(any(), #http2c_state{}) ->
                         {noreply, #http2c_state{}} |
                         {noreply, #http2c_state{}, timeout()} |
                         {stop, any(), #http2c_state{}}.
handle_info({ssl, _, Bin}, #http2c_state{
                              incoming_frames = Frames
                             } =  State) when is_binary(Bin) ->
    lager:debug("Incoming to http2c: ~p", [Bin]),
    [F] = http2_frame:from_binary(Bin),
    lager:debug("Cli Frame: ~p", [F]),
    {noreply, State#http2c_state{incoming_frames = Frames ++ [F]}};
handle_info(Info, State) ->
    lager:debug("unexpected []: ~p~n", [Info]),
    {noreply, State}.

%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(any(), #http2c_state{}) -> any().
terminate(_Reason, _State) ->
    ok.

%% Convert process state when code is changed
-spec code_change(any(), #http2c_state{}, any()) ->
                         {ok, #http2c_state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
