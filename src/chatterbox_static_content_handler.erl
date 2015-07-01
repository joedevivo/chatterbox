-module(chatterbox_static_content_handler).

-include("http2.hrl").

-export([handle/3]).

-spec handle(connection_state(),
             hpack:headers(),
             http2_stream:stream_state()) -> {
              http2_stream:stream_state(),
              connection_state()}.
handle(C = #connection_state{
         encode_context=EncodeContext,
         send_settings=SS=#settings{initial_window_size=SendWindowSize},
         recv_settings=#settings{initial_window_size=RecvWindowSize}
        }, Headers, Stream = #stream_state{stream_id=StreamId}) ->
    Path = binary_to_list(proplists:get_value(<<":path">>, Headers)),

    %% QueryString Hack?
    Path2 = case string:chr(Path, $?) of
        0 -> Path;
        X -> string:substr(Path, 1, X-1)
    end,

    %% Dot Hack
    Path3 = case Path2 of
        [$.|T] -> T;
        Other -> Other
    end,

    %% TODO: Should have a better way of extracting root_dir (i.e. not on every request)
    StaticHandlerSettings = application:get_env(chatterbox, ?MODULE, []),
    RootDir = proplists:get_value(root_dir, StaticHandlerSettings, code:priv_dir(chatterbox)),

    %% TODO: Logic about "/" vs "index.html", "index.htm", etc...
    %% Directory browsing?
    File = RootDir ++ Path3,
    lager:debug("[chatterbox_static_content_handler] serving ~p on stream ~p", [File, StreamId]),
    lager:info("Request Headers: ~p", [Headers]),
    {NewEncodeContext, Frames, PushPromises} = case {filelib:is_file(File), filelib:is_dir(File)} of
        {_, true} ->
            ResponseHeaders = [
                               {<<":status">>,<<"403">>}
                              ],

            {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, ResponseHeaders, EncodeContext),
            DataFrames = http2_frame_data:to_frames(StreamId, <<"No soup for you!">>, SS),
            {NewContext, [HeaderFrame|DataFrames], {undefined,[]}};
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

            %% TODO: In here we want to try and serve push promises based on HTML content

            %% Only push if it's HTML and server push is enabled



            %% 5) create streams for promised resources
            %% 6) Run this content handler on them
            {_, PromisesToFrame} = PPs = case {SS#settings.enable_push, MimeType} of
                {1, <<"text/html">>} ->
                    %% Search Data for resources to push
                    {ok, RE} = re:compile("<link rel=\"stylesheet\" href=\"([^\"]*)|<script src=\"([^\"]*)|src: '([^']*)"),
                    Resources = case re:run(Data, RE, [global, {capture,all,binary}]) of
                        {match, Matches} ->
                            [dot_hack(lists:last(M)) || M <- Matches];
                        _ -> []
                    end,

                    lager:debug("Resources to push: ~p", [Resources]),
                    %% Create Push Promise Frames & Streams
                    %% Send a bunch of PUSH PROMISES on this stream id that look like
                    %%    :method: GET
                    %%    :path: Resouce
                    %%    :scheme and :authority copied from request
                    {NextStreamId, Promises} = lists:foldl(
                        fun(Resource, {NextStreamIdAcc, Ps}) ->
                                {NextStreamIdAcc+2,
                                 [{generate_push_promise_headers(Headers, Resource),
                                   http2_stream:new(NextStreamIdAcc,
                                                    {SendWindowSize, RecvWindowSize},
                                                    reserved_local)}
                                  |Ps]}
                        end,
                        {C#connection_state.next_available_stream_id, []},
                        Resources),
                    {NextStreamId, lists:reverse(Promises)};
                _ ->
                    {undefined,[]}
            end,
            %% So what we have here now in PromisesToFrame is a list
            %% of {headers(), stream_state()}. So we'll fold over it
            %% and create a list of {frame_header(), push_promise()},
            %% which we'll send over the wire before we serve this
            %% content. We'll also accumulate the new encode context,
            %% because every set of push_promise headers needs to go
            %% through the encoding context in order

            {PromiseFrames, PostPromiseFrameEncodeContext} = lists:foldl(
                fun({PromiseHeaders, PromiseStream}, {FrameAcc, OldContext}) ->
                    {PromiseFrame, NewerContext} = http2_frame_push_promise:to_frame(
                                                     StreamId,
                                                     PromiseStream#stream_state.stream_id,
                                                     PromiseHeaders,
                                                     OldContext
                                                    ),
                    {[PromiseFrame|FrameAcc], NewerContext}
                end,
                {[],EncodeContext},
                PromisesToFrame
            ),

            %% So now it's time to craft the response that goes over
            %% this stream
            ResponseHeaders = [
                {<<":status">>, <<"200">>},
                {<<"content-type">>, MimeType}
            ],
            %% One more trip through the encoding context
            {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, ResponseHeaders, PostPromiseFrameEncodeContext),
            DataFrames = http2_frame_data:to_frames(StreamId, Data, SS),
            %% We're returning our new EncodeContext, A list of frames
            %% to send in order, and a tuple of
            %% {NextAvailableStreamId, [{headers(),
            %% stream_state()]}. After we send the content and finish
            %% up here, we'll send stuff from the other streams
            {NewContext, lists:reverse(PromiseFrames) ++ [HeaderFrame|DataFrames], PPs};
        {false, false} ->
            ResponseHeaders = [
                {<<":status">>, <<"404">>}
            ],
            {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, ResponseHeaders, EncodeContext),
            DataFrames = http2_frame_data:to_frames(StreamId, <<>>, SS),
            {NewContext, [HeaderFrame|DataFrames], {undefined,[]}}
        end,

    %% This is a baller fold right here. Fauxnite State Machine at its finest.
    %% Flush this stream and send it all.
    {DoneMainStream, PrePromiseConnectionState} = lists:foldl(
      fun(Frame, State) ->
              http2_stream:send_frame(Frame, State)
      end,
      {Stream, C#connection_state{encode_context=NewEncodeContext}},
      Frames),
    %% Now start sending things over the streams we've promised.
    case PushPromises of
        %% unless we've promised nothing, then just return the states
        %% as they were.
        {undefined, _} ->
            {DoneMainStream, PrePromiseConnectionState};
        {NextAvailStreamId, PromisesToKeep} ->
            FinalConn = lists:foldl(
                          fun({NHeaders, NStream}, AccConn=#connection_state{streams=PPStreams}) ->
                                  {DonePromiseStream, DonePromiseConn} = handle(AccConn, NHeaders, NStream),
                                  DonePromiseConn#connection_state{
                                    streams=[{DonePromiseStream#stream_state.stream_id, DonePromiseStream}|PPStreams]
                                  }
                          end,
                          PrePromiseConnectionState,
                          PromisesToKeep),
            {DoneMainStream, FinalConn#connection_state{next_available_stream_id=NextAvailStreamId}}
    end.

-spec generate_push_promise_headers(hpack:headers(), binary()) -> hpack:headers().
generate_push_promise_headers(Request, Path) ->
    [
     {<<":path">>, Path},{<<":method">>, <<"GET">>}|
     lists:filter(fun({<<":authority">>,_}) -> true;
                     ({<<":scheme">>, _}) -> true;
                     (_) -> false end, Request)
    ].

-spec dot_hack(binary()) -> binary().
dot_hack(<<$.,Bin/binary>>) ->
    Bin;
dot_hack(Bin) -> Bin.
