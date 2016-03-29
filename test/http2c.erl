%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% PLEASE ONLY USE FOR TESTING
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(http2c).

-behaviour(gen_server).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

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
         send_binary/2,
         send_unaltered_frames/2,
         get_frames/2,
         wait_for_n_frames/3
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(http2c_state, {
          socket :: undefined | {gen_tcp, gen_tcp:socket()} | {ssl, ssl:sslsocket()},
          send_settings = #settings{} :: settings(),
          encode_context = hpack:new_context() :: hpack:context(),
          next_available_stream_id = 1 :: pos_integer(),
          incoming_frames = [] :: [frame()],
          working_frame_header = undefined :: undefined | frame_header(),
          working_frame_payload = <<>> :: binary(),
          working_length = 0 :: non_neg_integer()
}).

%% Starts a server. Should probably take args eventually
-spec start_link() -> {ok, pid()} | ignore | {error, any()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% Three API levels:
%% 1: lowest: Send a frame or set of frames
%% 2: middle: Here's some hastily constucted frames, do some setup of frame header flags.
%% 3: highest: a semantic http request: **NOT IMPLEMENTED HERE*

%% send_binary/2 is the lowest level API. It just puts bits on the
%% wire
-spec send_binary(pid(), iodata()) -> ok.
send_binary(Pid, Binary) ->
    gen_server:cast(Pid, {send_bin, Binary}).

%% send_unaltered_frames is the raw version of the middle level. You
%% can put frames directly as constructed on the wire. This is
%% desgined for testing error conditions by giving you the freedom to
%% create bad sets of frames. This will problably only be exported
%% ifdef(TEST)
-spec send_unaltered_frames(pid(), [frame()]) -> ok.
send_unaltered_frames(Pid, Frames) ->
    [ send_binary(Pid, http2_frame:to_binary(F)) || F <- Frames],
    ok.

get_frames(Pid, StreamId) ->
    gen_server:call(Pid, {get_frames, StreamId}).

wait_for_n_frames(Pid, StreamId, N) ->
    wait_for_n_frames(Pid, StreamId, N, 0, []).

wait_for_n_frames(_Pid, StreamId, N, Attempts, Acc)
  when Attempts > 20 ->
    lager:error("Timed out waiting for ~p frames on Stream ~p", [N, StreamId]),
    lager:error("Did receive ~p frames.", [length(Acc)]),
    lager:error("  those frames were ~p", [Acc]),
    case length(Acc) == N of
        true ->
            Acc;
        _ ->
            ?assertEqual(length(Acc), length([])),
            []
    end;
wait_for_n_frames(Pid, StreamId, N, Attempts, Acc) ->
    Frames = Acc ++ get_frames(Pid, StreamId),

    case length(Frames) >= N of
        true ->
            lager:info("Frames: ~p ~p", [N, Frames]),
            ?assertEqual(N, length(Frames)),
            Frames;
        false ->
            timer:sleep(100),
            wait_for_n_frames(Pid, StreamId, N, Attempts + 1, Frames)
    end.

%% gen_server callbacks

%% Initializes the server
-spec init(list()) -> {ok, #http2c_state{}} |
                      {ok, #http2c_state{}, timeout()} |
                      ignore |
                      {stop, any()}.
init([]) ->
    Host = "localhost",
    {ok, Port} = application:get_env(chatterbox, port),
    ClientOptions = [
               binary,
               {packet, raw},
               {active, false}
              ],
    %% TODO: Stealing from the server config here :/
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

    %% Send the preamble
    Transport:send(Socket, <<?PREFACE>>),

    %% Settings Handshake
    {_SSH, ServerSettings} = http2_frame:read({Transport, Socket}, 1000),
    http2_frame_settings:ack({Transport, Socket}),

    ClientSettings = #settings{},

    BinToSend = http2_frame_settings:send(#settings{}, ClientSettings),
    Transport:send(Socket, BinToSend),

    {AH, PAck} = http2_frame:read({Transport, Socket}, 100),
    lager:debug("AH: ~p, ~p", [AH, PAck]),
    Ack = ?IS_FLAG(AH#frame_header.flags, ?FLAG_ACK),
    lager:debug("Ack: ~p", [Ack]),

    case Transport of
        ssl ->
            ssl:setopts(Socket, [{active, true}]);
        gen_tcp ->
            inet:setopts(Socket, [{active, true}])
    end,
    {ok, #http2c_state{
            socket = {Transport, Socket},
            send_settings = http2_frame_settings:overlay(#settings{},  ServerSettings)
           }}.

%% Handling call messages
-spec handle_call(term(), {pid(), term()} , #http2c_state{}) ->
                         {reply, any(), #http2c_state{}} |
                         {reply, any(), #http2c_state{}, timeout()} |
                         {noreply, #http2c_state{}} |
                         {noreply, #http2c_state{}, timeout()} |
                         {stop, any(), any(), #http2c_state{}} |
                         {stop, any(), #http2c_state{}}.
handle_call(new_stream_id, _From, #http2c_state{next_available_stream_id=Next}=State) ->
    {reply, Next, State#http2c_state{next_available_stream_id=Next+2}};
handle_call(encode_context, _From, #http2c_state{encode_context=EC}=State) ->
    {reply, EC, State};
handle_call({get_frames, StreamId}, _From, #http2c_state{incoming_frames=IF}=S) ->
    {ToReturn, ToPutBack} = lists:partition(fun({#frame_header{stream_id=SId},_}) -> StreamId =:= SId end, IF),
    {reply, ToReturn, S#http2c_state{incoming_frames=ToPutBack}};
handle_call(send_settings, _From, #http2c_state{send_settings=S}) ->
    {reply, S};
handle_call(Request, _From, State) ->
    {reply, {unknown_request, Request}, State}.

%% Handling cast messages
-spec handle_cast(any(), #http2c_state{}) ->
                         {noreply, #http2c_state{}} |
                         {noreply, #http2c_state{}, timeout()} |
                         {stop, any(), #http2c_state{}}.
handle_cast({send_bin, Bin}, #http2c_state{socket={Transport, Socket}}=State) ->
    lager:debug("Sending ~p", [Bin]),
    Transport:send(Socket, Bin),
    {noreply, State};
handle_cast(recv, #http2c_state{
                     socket={Transport, Socket},
                     incoming_frames = Frames
        }=State) ->
    RawHeader = Transport:recv(Socket, 9),
    {FHeader, <<>>} = http2_frame:read_binary_frame_header(RawHeader),
    lager:info("http2c recv ~p", [FHeader]),
    RawBody = Transport:recv(Socket, FHeader#frame_header.length),
    {ok, Payload, <<>>} = http2_frame:read_binary_payload(RawBody, FHeader),
    F = {FHeader, Payload},
    gen_server:cast(self(), recv),
    {noreply, State#http2c_state{incoming_frames = Frames ++ [F]}};
handle_cast({encode_context, EC}, State=#http2c_state{}) ->
    {noreply, State#http2c_state{encode_context=EC}};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% Handling all non call/cast messages
-spec handle_info(any(), #http2c_state{}) ->
                         {noreply, #http2c_state{}} |
                         {noreply, #http2c_state{}, timeout()} |
                         {stop, any(), #http2c_state{}}.
handle_info({_, _, Bin}, #http2c_state{
        incoming_frames = Frames,
        working_frame_header = WHeader,
        working_frame_payload = WPayload
    } = State) ->
    {NewFrames, Header, Rem} = process_binary(Bin, WHeader, WPayload, Frames),
    {noreply, State#http2c_state{
        incoming_frames = NewFrames,
        working_frame_header = Header,
        working_frame_payload = Rem
    }};
handle_info({tcp_closed,_}, State) ->
    {noreply, State};
handle_info({ssl_closed,_}, State) ->
    {noreply, State};
handle_info(Info, State) ->
    lager:debug("unexpected [http2c]: ~p~n", [Info]),
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
-spec process_binary(
    binary(),
    frame_header() | undefined,
    binary(),
    [frame()]) -> {[frame()], frame_header() | undefined, binary() | undefined}.
%%OMG probably a monad
process_binary(<<>>, undefined, <<>>, Frames) -> {Frames, undefined, <<>>};

process_binary(<<HeaderBin:9/binary,Bin/binary>>, undefined, <<>>, Frames) ->
    {Header, <<>>} = http2_frame:read_binary_frame_header(HeaderBin),
    L = Header#frame_header.length,
    case byte_size(Bin) >= L of
        true ->
            {ok, Payload, Rem} = http2_frame:read_binary_payload(Bin, Header),
            process_binary(Rem, undefined, <<>>, Frames ++ [{Header,Payload}]);
        false ->
            {Frames, Header, Bin}
    end;
process_binary(Bin, Header, <<>>, Frames) ->
    lager:info("process_binary(~p,~p,~p,~p", [Bin,Header,<<>>,Frames]),
    L = Header#frame_header.length,
    case byte_size(Bin) >= L of
        true ->
            {ok, Payload, Rem} = http2_frame:read_binary_payload(Bin, Header),
            process_binary(Rem, undefined, <<>>, Frames ++ [{Header,Payload}]);
        false ->
            {Frames, Header, Bin}
    end;
process_binary(Bin, Header, Payload, Frames) ->
    process_binary(iolist_to_binary([Payload, Bin]), Header, <<>>, Frames).
