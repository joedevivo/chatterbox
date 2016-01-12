-module(http2_client).

-behaviour(gen_fsm).

-include("http2.hrl").

-export([start_link/1]).

-export([send_request/3,
	 send_request_sync/4]).

-export([init/1,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 code_change/4,
	 terminate/3]).

-export([connected/2]).

-record(parser, {
	  wfh = undefined :: frame_header(),
	  wfp = <<>> :: binary(),
	  frames = [] :: [frame()]
	 }).

-record(stream, {
	  sender :: pid(),
	  frames :: [frame()]
	 }).

-record(state, {
	  connection,
	  client_settings,
	  server_settings,
	  nas = 1 :: pos_integer(),
	  parser = #parser{} :: #parser{},
	  streams = dict:new() :: dict:dict()
	 }).

-type option() :: {host, string()} |
		  {port, non_neg_integer()} |
		  {ssl, boolean()} |
		  {ssl_opts, list()}.

-spec start_link([option()]) ->
                        {ok, pid()} |
                        ignore |
                        {error, term()}.
start_link(Options) when is_list(Options) ->
    Host = proplists:get_value(host, Options),
    Port = proplists:get_value(port, Options),
    {Transport, ClientOptions} = client_options(Options),
    case Transport:connect(Host, Port, ClientOptions) of
	{ok, Socket} ->
	    ConnectionState = #connection_state{socket = {Transport, Socket}},
	    handshake_connection(#state{connection=ConnectionState},
				 Options);
	{error, timeout} ->
	    {error, timeout};
	Error ->
	    Error
    end.

send_request(Pid, Headers, Body) ->
    gen_fsm:send_event(Pid, {send_request, Headers, Body, []}).

send_request_sync(Pid, Headers, Body, Timeout) ->
    Sender = self(),
    gen_fsm:send_event(Pid, {send_request, Headers, Body, [{sender, Sender}]}),
    receive
	{http2, {frame, Frame}} ->
	    Frame
    after Timeout ->
	    timeout
    end.

init([#state{connection=#connection_state{socket={Transport, Socket}}}=State]) ->
    % The connection has been successfully handshaked before the process is
    % started.
    Transport:setopts(Socket, [{active, true}]),
    {ok, connected, State}.

connected({send_request, Headers, Body, Options},
	  #state{nas=Nas, connection=Connection, streams=Streams}=State) ->
    Stream = #stream{sender=proplists:get_value(sender, Options)},
    Streams1 = dict:store(Nas, Stream, Streams),
    {HeaderFrame, Connection1} = frame_headers(Headers, Nas, Connection),
    DataFrame = frame_body(Body, Nas, Connection),
    send_frames([HeaderFrame|DataFrame], Connection),
    {next_state, connected, State#state{connection=Connection1, nas=Nas+2,
					streams = Streams1}};
connected(_Event, State) ->
    {next_state, connected, State}.

handle_event(_Event, FsmState, State) ->
    {next_state, FsmState, State}.

handle_sync_event(_Event, _From, FsmState, State) ->
    {next_state, FsmState, State}.

handle_info({_Transport, _Socket, Data}, connected,
	    #state{parser=Parser,
		   streams=Streams}=State) ->
    lager:debug("Data ~p", [Data]),
    {Frames, Parser1} = process_binary(Data, Parser),
    lager:error("Frames ~p", [Frames]),
    Streams1 = notify_senders(Frames, Streams),
    {next_state, connected, State#state{parser=Parser1, streams=Streams1}}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    lager:debug("terminate reason: ~p~n", [_Reason]).

% Internal
notify_senders([], Streams) ->
    Streams;
notify_senders([{#frame_header{stream_id=SID}, _}=Frame|Frames],
	       Streams) ->
    case dict:find(SID, Streams) of
	{ok, #stream{sender=Pid}} ->
	    Parsed = parse_frame(Frame),
	    Pid ! {http2, {frame, Parsed}},
	    Streams1 = remove_stream(Frame, Streams),
	    notify_senders(Frames, Streams1);
	error ->
	    notify_senders(Frames, Streams)
    end.

parse_frame({#frame_header{type = ?HEADERS}, #headers{block_fragment=BF}}) ->
    Ctx = hpack:new_decode_context(),
    {Headers, _} = hpack:decode(BF, Ctx),
    {headers, Headers};
parse_frame(Frame) ->
    Frame.

remove_stream(#frame_header{flags = 1, stream_id = SID}, Streams) ->
    dict:erase(SID, Streams);
remove_stream(_, Streams) ->
    Streams.

frame_body(Body, Nas, #connection_state{send_settings=SS}) ->
    http2_frame_data:to_frames(Nas, Body, SS).

frame_headers(Headers, Nas, #connection_state{encode_context=EC}=Connection) ->
    {HeaderFrame, EC1} = http2_frame_headers:to_frame(Nas, Headers, EC),
    {HeaderFrame, Connection#connection_state{encode_context=EC1}}.

send_frames(Frames, #connection_state{socket={Transport, Socket}}) ->
    [Transport:send(Socket, http2_frame:to_binary(F)) || F <- Frames].

handshake_connection(#state{connection=#connection_state{socket={Transport, Socket}}}=State,
		     _Options) ->
    ok = Transport:send(Socket, <<?PREAMBLE>>),
    ClientSettings = #settings{},
    http2_frame_settings:send({Transport, Socket}, #settings{}, ClientSettings),
    case http2_frame:read({Transport, Socket}) of
	{AH, _Ack} ->
	    Ack = ?IS_FLAG(AH#frame_header.flags, ?FLAG_ACK),
	    lager:debug("Ack: ~p", [Ack]),
	    case http2_frame:read({Transport, Socket}) of
		{_SSH, ServerSettings} ->
		    ConnectionState = #connection_state{
					 socket = {Transport, Socket},
					 recv_settings = ClientSettings,
					 send_settings = http2_frame_settings:overlay(#settings{}, ServerSettings)
					},
		    start_fsm(State#state{connection = ConnectionState});
		Error ->
		    Error
	    end;
	Error ->
	    Error
    end.

start_fsm(#state{connection=#connection_state{socket={Transport,
						      Socket}}}=State) ->
    case gen_fsm:start_link(?MODULE, [State], []) of
	{ok, Pid} ->
	    Transport:controlling_process(Socket, Pid),
	    {ok, Pid};
	Error ->
	    Error
    end.

client_options(Options) ->
    ClientOptions = [binary, {packet, raw}, {active, false}],
    case proplists:get_value(ssl, Options, false) of
	false -> {gen_tcp, ClientOptions};
	true ->
	    SSLOptions = proplists:get_value(ssl_opts, Options, []),
	    {ssl, ClientOptions ++ SSLOptions ++
		 [{client_preferred_next_protocols, {client, [<<"h2">>]}}]}
    end.

process_binary(<<>>, #parser{frames=Frames}=Parser) ->
    {Frames, Parser#parser{frames = []}};
process_binary(<<HeaderBin:9/binary,Bin/binary>>,
	       #parser{frames = Frames,
		       wfp = <<>>,
		       wfh = undefined} = Parser) ->
    {Header, <<>>} = http2_frame:read_binary_frame_header(HeaderBin),
    case byte_size(Bin) >= Header#frame_header.length of
        true ->
            {ok, Payload, Rem} = http2_frame:read_binary_payload(Bin, Header),
	    process_binary(Rem, Parser#parser{
				  frames = Frames ++ [{Header,Payload}]});
        false ->
	    {Frames, Parser#parser{wfh = Header, wfp = Bin, frames = []}}
    end;
process_binary(Bin, #parser{wfh = Header, wfp = <<>>,
			    frames = Frames}=Parser) ->
    case byte_size(Bin) >= Header#frame_header.length of
        true ->
            {ok, Payload, Rem} = http2_frame:read_binary_payload(Bin, Header),
	    process_binary(Rem, Parser#parser{
				  wfh = undefined,
				  wfp = <<>>,
				  frames = Frames ++ [{Header,Payload}]});
        false ->
	    {Frames, Parser#parser{wfh = Header, wfp = Bin, frames = []}}
    end;
process_binary(Bin, #parser{wfp=Wfp}=Parser) ->
    process_binary(iolist_to_binary([Wfp, Bin]), Parser#parser{wfp = <<>>}).

