-module(http2_client).

-include("http2.hrl").

%% Today's the day! We need to turn this gen_server into a gen_fsm
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
         send_binary/2,
         send_frames/2,
         send_unaltered_frames/2,
         send_request/3,
         get_frames/2
        ]).


%% this is gonna get weird. start_link/* is going to call
%% http2_socket's start_link function, which will handle opening the
%% socket and sending the HTTP/2 Preface over the wire. Once that's
%% working, it's going to call gen_fsm:start_link(http2c, [SocketPid],
%% []) which will then use our init/1 callback. You can't actually
%% start this gen_fsm with this API. That's intentional, it will
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
                 non_neg_integer() | [ssl:ssloptions()]) ->
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
                 [ssl:ssloption()]) ->
                        {ok, pid()}
                      | ignore
                      | {error, term()}.
start_link(Transport, Host, Port, SSLOptions) ->
    NewT = case Transport of
               http -> gen_tcp;
               https -> ssl
           end,
    http2_socket:start_client_link(NewT, Host, Port, SSLOptions).

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
