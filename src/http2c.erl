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
         start_link/1,
         send_binary/2,
         send_frames/2,
         send_unaltered_frames/2,
         send_request/3,
         get_frames/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(http2c_state, {
          connection = #connection_state{} :: connection_state(),
          next_available_stream_id = 1 :: pos_integer(),
          incoming_frames = [] :: [frame()],
          working_frame_header = undefined :: undefined | frame_header(),
          working_frame_payload = <<>> :: binary(),
          working_length = 0 :: non_neg_integer()
}).

%% Starts a server. Should probably take args eventually
-spec start_link(any()) -> {ok, pid()} | ignore | {error, any()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).

%% Three API levels:
%% 1: lowest: Send a frame or set of frames
%% 2: middle: Here's some hastily constucted frames, do some setup of frame header flags.
%% 3: highest: a semantic http request: here are

%% send_binary/2 is the lowest level API. It just puts bits on the
%% wire
-spec send_binary(pid(), iodata()) -> ok.
send_binary(Pid, Binary) ->
    gen_server:cast(Pid, {send_bin, Binary}).

%% send_frames is the middle level. Converts a series of frames to
%% binary and sends them over to send_binary. It will scrub the frame
%% headers correctly, for example if you try to add a HEADERS frame
%% and two CONTINUATION frames, no matter what flags are set in the
%% frame headers, it will make sure that the HEADERS frame and the
%% FIRST CONTINUATION frame have the END_HEADERS flag set to 0 and the
%% SECOND CONTINUATION frame will have it set to 1.
-spec send_frames(pid(), [frame()]) -> ok.
send_frames(Pid, Frames) ->
    %% TODO Process Frames
    MassagedFrames = Frames,
    %% Then Send
    send_unaltered_frames(Pid, MassagedFrames).

%% send_unaltered_frames is the raw version of the middle level. You
%% can put frames directly as constructed on the wire. This is
%% desgined for testing error conditions by giving you the freedom to
%% create bad sets of frames. This will problably only be exported
%% ifdef(TEST)
-spec send_unaltered_frames(pid(), [frame()]) -> ok.
send_unaltered_frames(Pid, Frames) ->
    [ send_binary(Pid, http2_frame:to_binary(F)) || F <- Frames],
    ok.

%% send_request takes a set of headers and a possible body. It's
%% broken up into HEADERS, CONTINUATIONS, and DATA frames, and that
%% list of frames is passed to send_frames. This one needs to be smart
%% about creating a new frame id
-spec send_request(pid(), hpack:headers(), binary()) ->
                          {hpack:headers(), binary()}.
send_request(Pid, Headers, Body) ->
    %% TODO: Turn Headers & Body into frames
    %% That means creating a new stream id
    %% Which means getting one from the gen_server state
    NewStreamId = gen_server:call(Pid, new_stream_id),
    EncodeContext = gen_server:call(Pid, encode_context),
    SendSettings = gen_server:call(Pid, send_settings),
    %% Use that to make frames
    {HeaderFrame, NewEncodeContext} = http2_frame_headers:to_frame(NewStreamId, Headers, EncodeContext),
    gen_server:cast(Pid, {encode_context, NewEncodeContext}),
    DataFrames = http2_frame_data:to_frames(NewStreamId, Body, SendSettings),
    send_frames(Pid, [HeaderFrame|DataFrames]),

    %% Pull data off the wire. How? Right now we just do a separent call
    {[],<<>>}.

get_frames(Pid, StreamId) ->
    gen_server:call(Pid, {get_frames, StreamId}).

%% gen_server callbacks

%% Initializes the server
-spec init(list()) -> {ok, #http2c_state{}} |
                      {ok, #http2c_state{}, timeout()} |
                      ignore |
                      {stop, any()}.
init([Options]) ->
    Host = proplists:get_value(host, Options),
    Port = proplists:get_value(port, Options),
    ClientOptions = [binary,
		     {packet, raw},
		     {active, false}],
    {Transport, Options1} =
	case proplists:get_value(ssl, Options, false) of
	    false ->
		{gen_tcp, ClientOptions};
	    true ->
		SSLOptions = proplists:get_value(ssl_opts, Options, []),
		{ssl, ClientOptions ++ SSLOptions ++
		     [{client_preferred_next_protocols, {client, [<<"h2">>]}}]}
	end,
    lager:debug("Options: ~p", [Options1]),
    lager:debug("Transport: ~p", [Transport]),
    {ok, Socket} = Transport:connect(Host, Port, Options1),

    %% Send the preamble
    ok = Transport:send(Socket, <<?PREAMBLE>>),

    %% Send the Settings Handshake before anything else.
    ClientSettings = #settings{},
    http2_frame_settings:send({Transport, Socket}, #settings{}, ClientSettings),
    {AH, _Ack} = http2_frame:read({Transport, Socket}),

    %% Read and accept the settings from the server. @todo handle errors here
    {_SSH, ServerSettings}  = http2_frame:read({Transport, Socket}),
    http2_frame_settings:ack({Transport, Socket}),
    lager:debug("Ack: ~p", [_Ack]),
    lager:debug("AH: ~p", [AH]),
    Ack = ?IS_FLAG(AH#frame_header.flags, ?FLAG_ACK),
    lager:debug("Ack: ~p", [Ack]),
    case Transport of
        ssl ->
            ssl:setopts(Socket, [{active, true}]);
        gen_tcp ->
            inet:setopts(Socket, [{active, true}])
    end,
    {ok, #http2c_state{
            connection = #connection_state{
                            socket = {Transport, Socket},
                            recv_settings = ClientSettings,
                            send_settings = http2_frame_settings:overlay(#settings{},  ServerSettings)
                           }
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
handle_call(encode_context, _From, #http2c_state{connection=#connection_state{encode_context=EC}}=State) ->
    {reply, EC, State};
handle_call({get_frames, StreamId}, _From, #http2c_state{incoming_frames=IF}=S) ->
    {ToReturn, ToPutBack} = lists:partition(fun({#frame_header{stream_id=SId},_}) -> StreamId =:= SId end, IF),
    {reply, ToReturn, S#http2c_state{incoming_frames=ToPutBack}};
handle_call(send_settings, _From, #http2c_state{connection=C}) ->
    {reply, C#connection_state.send_settings};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% Handling cast messages
-spec handle_cast(any(), #http2c_state{}) ->
                         {noreply, #http2c_state{}} |
                         {noreply, #http2c_state{}, timeout()} |
                         {stop, any(), #http2c_state{}}.
handle_cast({send_bin, Bin}, #http2c_state{connection=#connection_state{socket={Transport, Socket}}}=State) ->
    lager:debug("Sending ~p", [Bin]),
    Transport:send(Socket, Bin),
    {noreply, State};
handle_cast(recv, #http2c_state{
        incoming_frames = Frames,
        connection=#connection_state{socket={Transport, Socket}}
        }=State) ->
    lager:info("recv"),


    RawHeader = Transport:recv(Socket, 9),
    {FHeader, <<>>} = http2_frame:read_binary_frame_header(RawHeader),
    lager:info("http2c recv ~p", [FHeader]),
    RawBody = Transport:recv(Socket, FHeader#frame_header.length),
    {ok, Payload, <<>>} = http2_frame:read_binary_payload(RawBody, FHeader),
    F = {FHeader, Payload},
    gen_server:cast(self(), recv),
    {noreply, State#http2c_state{incoming_frames = Frames ++ [F]}};
handle_cast({encode_context, EC}, State=#http2c_state{connection=C}) ->
    {noreply, State#http2c_state{connection=C#connection_state{encode_context=EC}}};
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
