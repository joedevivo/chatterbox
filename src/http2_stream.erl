-module(http2_stream).

-include("http2.hrl").

-export([recv_frame/2, send_frame/2, new/2]).

%% Yodawg_fsm. Abstracted here for readability and possible reuse on
%% the client side. !NO! This module will need understanding of the
%% underlying state which will be chatterbox_fsm_state OR http2c_state

%% idle streams don't actually exist, and may never exist. Isn't that
%% fun? According to my interpretation of the spec, every stream from
%% 1 to 2^31 is idle when the connection is open, unless the
%% connection was upgraded from HTTP/1, in which case stream 1 might
%% be in a different state. Rather than keep track of all those 2^31
%% streams, just assume that if we don't know about it, it's idle. Of
%% course, whenever a stream of id N is opened, all streams <N that
%% were idle are considered closed. Where we'll account for this? who
%% knows? probably in the chatterbox_fsm

-spec new(stream_id(), {pos_integer(), pos_integer()}) -> stream_state().
new(StreamId, {SendWindowSize, RecvWindowSize}) ->
    #stream_state{
       stream_id=StreamId,
       send_window_size = SendWindowSize,
       recv_window_size = RecvWindowSize
      }.



-spec recv_frame(frame(), stream_state()) -> stream_state().
%% First clause will handle transitions from idle to
%% half_closed_remote, via HEADERS frame with END_STREAM flag set
recv_frame({FH = #frame_header{
              stream_id=StreamId,
              type=?HEADERS
             }, _Payload},
           State = #stream_state{state=idle})
when ?IS_FLAG(FH#frame_header.flags, ?FLAG_END_STREAM) ->
    State#stream_state{
      stream_id = StreamId,
      state = half_closed_remote
     };
%% This one goes to open, because it's a headers frame, but not the
%% end of stream
recv_frame({_FH = #frame_header{
              stream_id=StreamId,
              type=?HEADERS
             }, _Payload},
           State = #stream_state{state=idle}) ->
    State#stream_state{
      stream_id = StreamId,
      state = open
     };
recv_frame(_F, S) ->
    S.


-spec send_frame(frame(), stream_state()) -> stream_state().
send_frame(_F, S) ->
    S.
