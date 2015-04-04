-define(SETTINGS_HEADER_TABLE_SIZE,         <<1>>).
-define(SETTINGS_ENABLE_PUSH,               <<2>>).
-define(SETTINGS_MAX_CONCURRENT_STREAMS,    <<3>>).
-define(SETTINGS_INITIAL_WINDOW_SIZE,       <<4>>).
-define(SETTINGS_MAX_FRAME_SIZE,            <<5>>).
-define(SETTINGS_MAX_HEADER_LIST_SIZE,      <<6>>).

-define(DATA            , 0).
-define(HEADERS         , 1).
-define(PRIORITY        , 2).
-define(RST_STREAM      , 3).
-define(SETTINGS        , 4).
-define(PUSH_PROMISE    , 5).
-define(PING            , 6).
-define(GOAWAY          , 7).
-define(WINDOW_UPDATE   , 8).
-define(CONTINUATION    , 9).


-type frame_type() :: ?DATA
                    | ?HEADERS
                    | ?PRIORITY
                    | ?RST_STREAM
                    | ?SETTINGS
                    | ?PUSH_PROMISE
                    | ?PING
                    | ?GOAWAY
                    | ?WINDOW_UPDATE
                    | ?CONTINUATION.

-record(header, {
    length      :: non_neg_integer(),
    type        :: frame_type(),
    flags       :: binary(),
    stream_id   :: binary()
    }).
-type header() :: #header{}.

-record(settings, {header_table_size        = 4096,
                   enable_push              = 1,
                   max_concurrent_streams   = unlimited,
                   initial_window_size      = 65535,
                   max_frame_size           = 16384,
                   max_header_list_size     = unlimited}).
-type settings() :: #settings{}.

-type payload() :: settings().