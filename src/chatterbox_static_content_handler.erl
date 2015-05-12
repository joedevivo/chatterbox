-module(chatterbox_static_content_handler).

-include("http2.hrl").

-export([handle/3]).

%% TODO lots about this module to make configurable. biggest one is priv_dir tho. Barfolomew

-spec handle(connection_state(), hpack:headers(), http2_stream:stream_state()) -> {connection_state(), http2_stream:stream_state()}.
handle(C = #connection_state{
         socket=Socket,
         encode_context=EncodeContext
        }, Headers, Stream = #stream_state{stream_id=StreamId}) ->
    Path = binary_to_list(proplists:get_value(<<":path">>, Headers)),
    File = code:priv_dir(chatterbox) ++ Path,
    lager:debug("serving ~p", [File]),
    NewEncodeContext = case filelib:is_file(File) of
        true ->
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
            http2_frame_data:send(Socket, StreamId, Data),
            NewContext;
        false ->
            ResponseHeaders = [
                {<<":status">>, <<"404">>}
            ],
            NewContext = http2_frame_headers:send(Socket, StreamId, ResponseHeaders, EncodeContext),

            http2_frame_data:send(Socket, StreamId, <<>>),
            NewContext
        end,
    {C#connection_state{encode_context=NewEncodeContext}, Stream}.
