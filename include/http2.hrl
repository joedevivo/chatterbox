-define(SETTINGS_HEADER_TABLE_SIZE,         <<16#1>>).
-define(SETTINGS_ENABLE_PUSH,               <<16#2>>).
-define(SETTINGS_MAX_CONCURRENT_STREAMS,    <<16#3>>).
-define(SETTINGS_INITIAL_WINDOW_SIZE,       <<16#4>>).
-define(SETTINGS_MAX_FRAME_SIZE,            <<16#5>>).
-define(SETTINGS_MAX_HEADER_LIST_SIZE,      <<16#6>>).

%% FRAME TYPES
-define(DATA            , 16#0).
-define(HEADERS         , 16#1).
-define(PRIORITY        , 16#2).
-define(RST_STREAM      , 16#3).
-define(SETTINGS        , 16#4).
-define(PUSH_PROMISE    , 16#5).
-define(PING            , 16#6).
-define(GOAWAY          , 16#7).
-define(WINDOW_UPDATE   , 16#8).
-define(CONTINUATION    , 16#9).


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

-define(DEFAULT_SETTINGS, #settings{}).

-type settings() :: #settings{}.

-type payload() :: settings().
