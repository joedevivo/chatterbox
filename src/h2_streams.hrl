
-record(
   active_stream, {
          id                    :: stream_id(),
          pid                   :: undefined | pid(),
          send_window_size      :: non_neg_integer(),
          recv_window_size      :: non_neg_integer(),
          queued_data           :: undefined | done | binary(),
          body_complete = false :: boolean(),
          response_headers      :: undefined | hpack:headers(),
          response_body         :: undefined | binary()
         }).

-record(
   closed_stream, {
     id               :: stream_id(),
     response_headers :: hpack:headers(),
     response_body    :: binary()
     }).

-type stream() :: #active_stream{}
                | #closed_stream{}.


-record(
   stream_set, {
     max_active = unlimited :: unlimited | pos_integer(),
     active_count = 0 :: non_neg_integer(),
     active = [] :: [stream()]
    }).
-type stream_set() :: #stream_set{}.

-record(
   streams, {
     type :: client | server,
     peer_initiated = #stream_set{} :: stream_set(),
     self_initiated = #stream_set{} :: stream_set()
    }
  ).
-type streams() :: #streams{}.
