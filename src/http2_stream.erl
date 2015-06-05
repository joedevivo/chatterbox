-module(http2_stream).

-include("http2.hrl").

-export([recv_frame/2, send_frame/2, new/3]).

-export_type([stream_state/0]).

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

-spec new(stream_id(), {pos_integer(), pos_integer()}, {gen_tcp|ssl, port()}) -> stream_state().
new(StreamId, {SendWindowSize, RecvWindowSize}, Socket) ->
    #stream_state{
       stream_id=StreamId,
       send_window_size = SendWindowSize,
       recv_window_size = RecvWindowSize,
       socket = Socket
      }.

-spec recv_frame(frame(), stream_state()) -> stream_state().
%% First clause will handle transitions from idle to
%% half_closed_remote, via HEADERS frame with END_STREAM flag set
recv_frame(F={FH = #frame_header{
              stream_id=StreamId,
              type=?HEADERS
             }, _Payload},
           State = #stream_state{state=idle})
when ?IS_FLAG(FH#frame_header.flags, ?FLAG_END_STREAM) ->
    State#stream_state{
      stream_id = StreamId,
      state = half_closed_remote,
      incoming_frames = [F]
     };
%% This one goes to open, because it's a headers frame, but not the
%% end of stream
recv_frame(F={_FH = #frame_header{
              stream_id=StreamId,
              type=?HEADERS
             }, _Payload},
           State = #stream_state{state=idle}) ->
    State#stream_state{
      stream_id = StreamId,
      state = open,
      incoming_frames = [F]
     };
recv_frame(F={#frame_header{
                 stream_id=StreamId,
                 type=?CONTINUATION
                }, _Payload},
           State = #stream_state{
                      stream_id=StreamId,
                      incoming_frames=Frames
                     }) ->
    State#stream_state{
      incoming_frames = [F|Frames]
     };

%% TODO : More ?DATA when L > RWS and when ?IS_FLAG(END_STREAM)
recv_frame(F={_FH=#frame_header{
                   length=L,
                   type=?DATA,
                   flags=Flags
                  }, _P},
          S = #stream_state{
                 recv_window_size=RWS,
                 incoming_frames=IF
                })
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    S#stream_state{
      recv_window_size=RWS-L,
      incoming_frames=IF ++ [F]
     };
%% needs a WINDOW_UPDATE clause badly
recv_frame({#frame_header{
               type=?WINDOW_UPDATE,
               stream_id=StreamId
              },
            #window_update{
               window_size_increment=WSI
              }
           },State=#stream_state{
                      stream_id=StreamId,
                      send_window_size=SWS,
                      queued_frames=QF
                     }) ->
    NewSendWindow = WSI + SWS,
    NewState = State#stream_state{
                 send_window_size=NewSendWindow,
                 queued_frames=[]
                },
    lager:info("Stream ~p send window now: ~p", [StreamId, NewSendWindow]),
    lists:foldl(
      fun(Frame, Stream) -> send_frame(Frame, Stream) end,
      NewState,
      QF);
recv_frame(_F, S) ->
    S.


-spec send_frame(frame(), stream_state()) -> stream_state().
send_frame(F={#frame_header{
                 type=?HEADERS
                },_},
           State = #stream_state{
                      socket={Transport,Socket}
                     }) ->
    Transport:send(Socket, http2_frame:to_binary(F)),
    State;
send_frame(F={#frame_header{
                 length=L,
                 type=?DATA
                },_Data},
           State = #stream_state{
                      send_window_size=SWS,
                      socket={Transport,Socket}
                     })
  when SWS >= L ->
    Transport:send(Socket, http2_frame:to_binary(F)),
    NewSendWindow = SWS - L,
    State#stream_state{
       send_window_size=NewSendWindow
      };
send_frame(F={#frame_header{
                 length=L,
                 type=?DATA
                },_Data},
           State = #stream_state{
                      send_window_size=SWS,
                      queued_frames = QF
                     })
  when SWS < L ->
    State#stream_state{
       queued_frames=QF ++ [F]
      };
send_frame(_F, S) ->
    S.
