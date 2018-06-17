-module(chatterbox_static_stream).

-include("http2.hrl").

-behaviour(h2_stream).

-export([
         init/3,
         on_receive_headers/2,
         on_send_push_promise/2,
         on_receive_data/2,
         on_end_stream/1
        ]).

-record(cb_static, {
        req_headers=[],
        connection_pid :: pid(),
        stream_id :: stream_id()
          }).

init(ConnPid, StreamId, _) ->
    %% You need to pull settings here from application:env or something
    {ok, #cb_static{connection_pid=ConnPid,
                    stream_id=StreamId}}.

on_receive_headers(Headers, State) ->
    {ok, State#cb_static{req_headers=Headers}}.

on_send_push_promise(Headers, State) ->
    {ok, State#cb_static{req_headers=Headers}}.

on_receive_data(_Bin, State)->
    {ok, State}.

on_end_stream(State=#cb_static{connection_pid=ConnPid,
                                       stream_id=StreamId}) ->
    Headers = State#cb_static.req_headers,

    Method = proplists:get_value(<<":method">>, Headers),

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
    {HeadersToSend, BodyToSend} =
        case {filelib:is_file(File), filelib:is_dir(File)} of
            {_, true} ->
                ResponseHeaders = [
                                   {<<":status">>,<<"403">>}
                                  ],
                {ResponseHeaders, <<"No soup for you!">>};
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

                case {MimeType, h2_connection:is_push(ConnPid)} of
                    {<<"text/html">>, true} ->
                        %% Search Data for resources to push
                        {ok, RE} = re:compile("<link rel=\"stylesheet\" href=\"([^\"]*)|<script src=\"([^\"]*)|src: '([^']*)"),
                        Resources = case re:run(Data, RE, [global, {capture,all,binary}]) of
                                        {match, Matches} ->
                                            [dot_hack(lists:last(M)) || M <- Matches];
                                        _ -> []
                                    end,

                        lists:foldl(
                          fun(R, Acc) ->
                                  {NewStreamId, _} = h2_connection:new_stream(ConnPid),
                                  PHeaders = generate_push_promise_headers(Headers, <<$/,R/binary>>
                                                                          ),
                                  h2_connection:send_promise(ConnPid, StreamId, NewStreamId, PHeaders),
                                  [{NewStreamId, PHeaders}|Acc]
                          end,
                          [],
                          Resources
                         ),
                        ok;
                    _ ->
                        ok
                end,

                %% For each chunk of data:

                %% 1. Ask the connection if it's got enough bytes in the
                %% send window.
                %% maybe just send the frame header?

                %% If it doesn't, we need to put this frame in a place
                %% that will get looked at when our connection window size
                %% increases.

                %% If it does, we still need to try and check stream level
                %% flow control.
                {ResponseHeaders, Data};
        {false, false} ->
            ResponseHeaders = [
                               {<<":status">>,<<"404">>}
                              ],
                {ResponseHeaders, <<"No soup for you!">>}
        end,

    case {Method, HeadersToSend, BodyToSend} of
        {<<"HEAD">>, _, _} ->
                h2_connection:send_headers(ConnPid, StreamId, HeadersToSend, [{send_end_stream, true}]);
        %%{<<"GET">>, _, _} ->
        _ ->
            h2_connection:send_headers(ConnPid, StreamId, HeadersToSend),
            h2_connection:send_body(ConnPid, StreamId, BodyToSend)
    end,

    {ok, State}.

%% Internal

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
