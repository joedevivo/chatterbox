-module(chatterbox_static_content_handler).

-include("http2.hrl").

-export([
         spawn_handle/4,
         handle/4
        ]).

-spec spawn_handle(
        pid(),
        stream_id(),     %% Stream Id
        hpack:headers(), %% Decoded Request Headers
        iodata()         %% Request Body
       ) -> pid().
spawn_handle(Pid, StreamId, Headers, ReqBody) ->
    Handler = fun() ->
        handle(Pid, StreamId, Headers, ReqBody)
    end,
    spawn_link(Handler).

-spec handle(
        pid(),
        stream_id(),
        hpack:headers(),
        iodata()
       ) -> ok.
handle(ConnPid, StreamId, Headers, _ReqBody) ->
    lager:debug("handle(~p, ~p, ~p, _)", [ConnPid, StreamId, Headers]),
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


    Path4 = case Path3 of
                [$/|T2] -> [$/|T2];
                Other2 -> [$/|Other2]
            end,

    %% TODO: Should have a better way of extracting root_dir (i.e. not on every request)
    StaticHandlerSettings = application:get_env(chatterbox, ?MODULE, []),
    RootDir = proplists:get_value(root_dir, StaticHandlerSettings, code:priv_dir(chatterbox)),

    %% TODO: Logic about "/" vs "index.html", "index.htm", etc...
    %% Directory browsing?
    File = RootDir ++ Path4,
    lager:debug("[chatterbox_static_content_handler] serving ~p on stream ~p", [File, StreamId]),
    lager:info("Request Headers: ~p", [Headers]),

    case {filelib:is_file(File), filelib:is_dir(File)} of
        {_, true} ->
            ResponseHeaders = [
                               {<<":status">>,<<"403">>}
                              ],
            http2_connection:send_headers(ConnPid, StreamId, ResponseHeaders),
            http2_connection:send_body(ConnPid, StreamId, <<"No soup for you!">>),
            ok;
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

            http2_connection:send_headers(ConnPid, StreamId, ResponseHeaders),


            case {MimeType, http2_connection:is_push(ConnPid)} of
                {<<"text/html">>, true} ->
                    %% Search Data for resources to push
                    {ok, RE} = re:compile("<link rel=\"stylesheet\" href=\"([^\"]*)|<script src=\"([^\"]*)|src: '([^']*)"),
                    Resources = case re:run(Data, RE, [global, {capture,all,binary}]) of
                        {match, Matches} ->
                            [dot_hack(lists:last(M)) || M <- Matches];
                        _ -> []
                    end,

                    lager:debug("Resources to push: ~p", [Resources]),

                    NewStreams =
                        lists:foldl(fun(R, Acc) ->
                                            NewStreamId = http2_connection:new_stream(ConnPid),
                                            PHeaders = generate_push_promise_headers(Headers, <<$/,R/binary>>),
                                            http2_connection:send_promise(ConnPid, StreamId, NewStreamId, PHeaders),
                                            [{NewStreamId, PHeaders}|Acc]
                                    end,
                                    [],
                                    Resources
                                   ),

                    lager:debug("New Streams for promises: ~p", [NewStreams]),

                    [spawn_handle(ConnPid, NewStreamId, PHeaders, <<>>) || {NewStreamId, PHeaders} <- NewStreams],

                    ok;
                _ ->
                    ok
            end,
            http2_connection:send_body(ConnPid, StreamId, Data),
            ok;
        {false, false} ->
            ResponseHeaders = [
                               {<<":status">>,<<"404">>}
                              ],
            http2_connection:send_headers(ConnPid, StreamId, ResponseHeaders),
            http2_connection:send_body(ConnPid, StreamId, <<"No soup for you!">>),
            ok
    end,
    ok.

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
