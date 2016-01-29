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

-define(FT, fun(?DATA) -> "DATA";
               (?HEADERS) -> "HEADERS";
               (?PRIORITY) -> "PRIORITY";
               (?RST_STREAM) -> "RST_STREAM";
               (?SETTINGS) -> "SETTINGS";
               (?PUSH_PROMISE) -> "PUSH_PROMISE";
               (?PING) -> "PING";
               (?GOAWAY) -> "GOAWAY";
               (?WINDOW_UPDATE) -> "WINDOW_UPDATE";
               (?CONTINUATION) -> "CONTINUATION" end
  ).

%% ERROR CODES
-define(NO_ERROR,           16#0).
-define(PROTOCOL_ERROR,     16#1).
-define(INTERNAL_ERROR,     16#2).
-define(FLOW_CONTROL_ERROR, 16#3).
-define(SETTINGS_TIMEOUT,   16#4).
-define(STREAM_CLOSED,      16#5).
-define(FRAME_SIZE_ERROR,   16#6).
-define(REFUSED_STREAM,     16#7).
-define(CANCEL,             16#8).
-define(COMPRESSION_ERROR,  16#9).
-define(CONNECT_ERROR,      16#a).
-define(ENHANCE_YOUR_CALM,  16#b).
-define(INADEQUATE_SECURITY,16#c).
-define(HTTP_1_1_REQUIRED,  16#d).

-type error_code() :: ?NO_ERROR
                    | ?PROTOCOL_ERROR
                    | ?INTERNAL_ERROR
                    | ?FLOW_CONTROL_ERROR
                    | ?SETTINGS_TIMEOUT
                    | ?STREAM_CLOSED
                    | ?FRAME_SIZE_ERROR
                    | ?REFUSED_STREAM
                    | ?CANCEL
                    | ?COMPRESSION_ERROR
                    | ?CONNECT_ERROR
                    | ?ENHANCE_YOUR_CALM
                    | ?INADEQUATE_SECURITY
                    | ?HTTP_1_1_REQUIRED.

%% FLAGS
-define(FLAG_ACK,         16#1 ).
-define(FLAG_END_STREAM,  16#1 ).
-define(FLAG_END_HEADERS, 16#4 ).
-define(FLAG_PADDED,      16#8 ).
-define(FLAG_PRIORITY,    16#20).

-type flag() :: ?FLAG_ACK
              | ?FLAG_END_STREAM
              | ?FLAG_END_HEADERS
              | ?FLAG_PADDED
              | ?FLAG_PRIORITY.

%% These are macros because they're used in guards alot
-define(IS_FLAG(Flags, Flag), Flags band Flag =:= Flag).
-define(NOT_FLAG(Flags, Flag), Flags band Flag =/= Flag).

-type stream_id() :: non_neg_integer().
-record(frame_header, {
    length      :: non_neg_integer(),
    type        :: frame_type(),
    flags = 0   :: non_neg_integer(),
    stream_id   :: stream_id()
    }).

-type frame_header() :: #frame_header{}.

-record(data, {
    data :: binary()
  }).
-type data() :: #data{}.

-record(headers, {
          priority = undefined :: priority() | undefined,
          block_fragment :: binary()
}).
-type headers() :: #headers{}.

-record(priority, {
    exclusive :: 0 | 1,
    stream_id :: stream_id(),
    weight :: pos_integer()
  }).
-type priority() :: #priority{}.

-record(rst_stream, {
          error_code :: error_code()
}).
-type rst_stream() :: #rst_stream{}.

-record(settings, {header_table_size        = 4096,
                   enable_push              = 1,
                   max_concurrent_streams   = unlimited,
                   initial_window_size      = 65535,
                   max_frame_size           = 16384,
                   max_header_list_size     = unlimited}).
-define(DEFAULT_SETTINGS, #settings{}).
-type settings() :: #settings{}.

-define(SETTINGS_HEADER_TABLE_SIZE,         <<16#1>>).
-define(SETTINGS_ENABLE_PUSH,               <<16#2>>).
-define(SETTINGS_MAX_CONCURRENT_STREAMS,    <<16#3>>).
-define(SETTINGS_INITIAL_WINDOW_SIZE,       <<16#4>>).
-define(SETTINGS_MAX_FRAME_SIZE,            <<16#5>>).
-define(SETTINGS_MAX_HEADER_LIST_SIZE,      <<16#6>>).

-define(SETTING_NAMES, [?SETTINGS_HEADER_TABLE_SIZE,
                        ?SETTINGS_ENABLE_PUSH,
                        ?SETTINGS_MAX_CONCURRENT_STREAMS,
                        ?SETTINGS_INITIAL_WINDOW_SIZE,
                        ?SETTINGS_MAX_FRAME_SIZE,
                        ?SETTINGS_MAX_HEADER_LIST_SIZE]).

-type setting_name() :: binary().


-type settings_property() :: {setting_name(), any()}.
-type settings_proplist() :: [settings_property()].

-record(push_promise, {
          promised_stream_id :: stream_id(),
          block_fragment :: binary()
}).
-type push_promise() :: #push_promise{}.

-record(ping, {
          opaque_data :: binary()
}).
-type ping() :: #ping{}.

-record(goaway, {
          last_stream_id :: stream_id(),
          error_code :: error_code(),
          additional_debug_data = <<>> :: binary()
}).
-type goaway() :: #goaway{}.

-record(window_update, {
          window_size_increment :: non_neg_integer()
}).
-type window_update() :: #window_update{}.

-record(continuation, {
          block_fragment :: binary()
}).
-type continuation() :: #continuation{}.

-type payload() :: data()
                 | headers()
                 | settings() | {settings, [proplists:property()]}
                 | priority()
                 | settings()
                 | rst_stream()
                 | push_promise()
                 | ping()
                 | goaway()
                 | window_update()
                 | continuation().

-type frame() :: {frame_header(), payload()}.


-type transport() :: gen_tcp | ssl.
-type socket() :: {gen_tcp, gen_tcp:socket()|undefined} | {ssl, ssl:sslsocket()|undefined}.

%% TODO: I don't know where I got PREAMBLE from, it's PREFACE in the spec
-define(PREAMBLE, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(PREFACE, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").

-define(DEFAULT_INITIAL_WINDOW_SIZE, 65535).


-record(connection_state, {
          ssl_options = [],
          listen_ref :: non_neg_integer(),
          socket = undefined :: undefined | pid(),
          send_settings = #settings{} :: settings(),
          recv_settings = #settings{} :: settings(),
          send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          decode_context = hpack:new_decode_context() :: hpack:decode_context(),
          encode_context = hpack:new_encode_context() :: hpack:encode_context(),

%% An effort to consolidate client and server states, which should actually be very similar
          settings_sent = queue:new() :: queue:queue(),
          next_available_stream_id = 2 :: stream_id(),
          streams = [] :: [{stream_id(), stream_state()}],
          continuation_stream_id = undefined :: stream_id() | undefined,
          content_handler = chatterbox_static_content_handler :: module()
}).

-type connection_state() :: #connection_state{}.

-type stream_state_name() :: 'idle'
                           | 'open'
                           | 'closed'
                           | 'reserved_local'
                           | 'reserved_remote'
                           | 'half_closed_local'
                           | 'half_closed_remote'.

-record(stream_state, {
          stream_id = undefined :: stream_id(),
          state = idle :: stream_state_name(),
          send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          queued_frames = queue:new() :: queue:queue(frame()),
          incoming_frames = queue:new() :: queue:queue(frame()),
          request_headers = [] :: hpack:headers(),
          request_body :: iodata(),
          request_end_stream = false :: boolean(),
          request_end_headers = false :: boolean(),
          response_headers = [] :: hpack:headers(),
          response_body :: iodata(),
          response_end_headers = false :: boolean(),
          response_end_stream = false :: boolean()
}).

-type stream_state() :: #stream_state{}.
