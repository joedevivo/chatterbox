-module(chatterbox_static_content_handler).

-include("http2.hrl").

-export([
         handle/3,
         send_while_window_open/2
        ]).

%% TODO lots about this module to make configurable. biggest one is priv_dir tho. Barfolomew

-spec handle(connection_state(), hpack:headers(), http2_stream:stream_state()) -> {connection_state(), http2_stream:stream_state()}.
handle(C = #connection_state{
         socket=Socket,
         encode_context=EncodeContext,
         send_settings=SS
        }, Headers, Stream = #stream_state{stream_id=StreamId}) ->
    Path = binary_to_list(proplists:get_value(<<":path">>, Headers)),

    %% QueryString Hack?
    Path2 = case string:chr(Path, $?) of
        0 -> Path;
        X -> string:substr(Path, 1, X-1)
    end,

    %% TODO: Should have a better way of extracting root_dir (i.e. not on every request)
    StaticHandlerSettings = application:get_env(chatterbox, ?MODULE, []),
    RootDir = proplists:get_value(root_dir, StaticHandlerSettings, code:priv_dir(chatterbox)),

    %% TODO: Logic about "/" vs "index.html", "index.htm", etc...
    %% Directory browsing?
    File = RootDir ++ Path2,
    lager:debug("serving ~p", [File]),
    lager:info("Request Headers: ~p", [Headers]),
    {NewEncodeContext, NewStream} = case {filelib:is_file(File), filelib:is_dir(File)} of
        {_, true} ->
            ResponseHeaders = [
                               {<<":status">>,<<"403">>}
                              ],

            NewContext = http2_frame_headers:send(Socket, StreamId, ResponseHeaders, EncodeContext),
            %% TODO: We know how much we can send, so send that and wait for a flow control update?
            Frames = http2_frame_data:to_frames(StreamId, <<"No soup for you!">>, SS),
            NStream = send_while_window_open(Stream#stream_state{queued_frames=Frames}, C),
            {NewContext, NStream};
        {true, false} ->
            Ext = filename:extension(File),
            MimeType = case Ext of
                ".js" -> <<"text/javascript">>;
                ".html" -> <<"text/html">>;
                ".css" -> <<"text/css">>;
                ".scss" -> <<"text/css">>;
                ".woff" -> <<"application/font-woff">>;
                ".ttf" -> <<"application/font-snft">>;
                _ -> <<"unknown">>
            end,
            {ok, Data} = file:read_file(File),
            ResponseHeaders = [
                {<<":status">>, <<"200">>},
                {<<"content-type">>, MimeType}
            ],
            NewContext = http2_frame_headers:send(Socket, StreamId, ResponseHeaders, EncodeContext),
            %% TODO: We know how much we can send, so send that and wait for a flow control update?
            Frames = http2_frame_data:to_frames(StreamId, Data, SS),

            NStream = send_while_window_open(Stream#stream_state{queued_frames=Frames}, C),

            {NewContext, NStream};
        {false, false} ->
            ResponseHeaders = [
                {<<":status">>, <<"404">>}
            ],
            NewContext = http2_frame_headers:send(Socket, StreamId, ResponseHeaders, EncodeContext),

            http2_frame_data:send(Socket, StreamId, <<>>, SS),
            {NewContext, Stream}
        end,
    {C#connection_state{encode_context=NewEncodeContext}, NewStream}.

send_while_window_open(
                       S = #stream_state{
                                         stream_id = StreamId,
                                         send_window_size=SWS,
                              queued_frames = [F=[<<L:24,_/binary>>, X]|Frames]
                             },
                      C = #connection_state{socket={Transport,Socket}}) when SWS >= L ->
    lager:info("Sending ~p over ~p", [byte_size(X), Transport]),
    Transport:send(Socket, F),
    NewSendWindow = SWS - L,
    lager:info("Stream ~p send window now: ~p", [StreamId, NewSendWindow]),
    send_while_window_open(S#stream_state{send_window_size=NewSendWindow, queued_frames=Frames}, C);
send_while_window_open(S, _C) ->
    S.
