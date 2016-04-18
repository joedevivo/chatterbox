
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
-type stream() :: #active_stream{}.

-type streams() :: [#active_stream{}].
