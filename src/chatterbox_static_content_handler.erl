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
    lager:debug("[chatterbox_static_content_handler] serving ~p", [File]),
    lager:info("Request Headers: ~p", [Headers]),
    {NewEncodeContext, Frames} = case {filelib:is_file(File), filelib:is_dir(File)} of
        {_, true} ->
            ResponseHeaders = [
                               {<<":status">>,<<"403">>}
                              ],

            {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, ResponseHeaders, EncodeContext),
            DataFrames = http2_frame_data:to_frames(StreamId, <<"No soup for you!">>, SS),
            {NewContext, [HeaderFrame|DataFrames]};
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
            {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, ResponseHeaders, EncodeContext),
            DataFrames = http2_frame_data:to_frames(StreamId, Data, SS),
            {NewContext, [HeaderFrame|DataFrames]};
        {false, false} ->
            ResponseHeaders = [
                {<<":status">>, <<"404">>}
            ],
            {HeaderFrame, NewContext} = http2_frame_headers:to_frame(StreamId, ResponseHeaders, EncodeContext),
            DataFrames = http2_frame_data:to_frames(StreamId, <<>>, SS),
            {NewContext, [HeaderFrame|DataFrames]}
        end,
    NewConnectionState = C#connection_state{encode_context=NewEncodeContext},

    %% This is a baller fold right here. Fauxnite State Machine at its finest.
    lists:foldl(
      fun(Frame, State) ->
              http2_stream:send_frame(Frame, State)
      end,
      {Stream, NewConnectionState},
      Frames).
