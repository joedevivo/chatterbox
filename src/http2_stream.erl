-module(http2_stream).

-include("http2.hrl").

-export([
         recv_frame/2,
         send_frame/2,
         new/2,
         new/3
        ]).

-export_type([stream_state/0]).

%% idle streams don't actually exist, and may never exist. Isn't that
%% fun? According to my interpretation of the spec, every stream from
%% 1 to 2^31 is idle when the connection is open, unless the
%% connection was upgraded from HTTP/1, in which case stream 1 might
%% be in a different state. Rather than keep track of all those 2^31
%% streams, just assume that if we don't know about it, it's idle. Of
%% course, whenever a stream of id N is opened, all streams <N that
%% were idle are considered closed. Where we'll account for this? who
%% knows? probably in the http2_connection

-spec new(stream_id(),
          {pos_integer(), pos_integer()}) ->
                 stream_state().
new(StreamId, {SendWindowSize, RecvWindowSize}) ->
    new(StreamId, {SendWindowSize, RecvWindowSize}, idle).

-spec new(stream_id(),
          {pos_integer(), pos_integer()},
          stream_state_name()) ->
                 stream_state().
new(StreamId, {SendWindowSize, RecvWindowSize}, StateName) ->
    #stream_state{
       stream_id=StreamId,
       send_window_size = SendWindowSize,
       recv_window_size = RecvWindowSize,
       state = StateName
      }.

-spec recv_frame(frame(), {stream_state(), connection_state()}) ->
                        {stream_state(), connection_state()}.
%% First clause will handle transitions from idle to
%% half_closed_remote, via HEADERS frame with END_STREAM flag set
recv_frame(F={FH = #frame_header{
              stream_id=StreamId,
              type=?HEADERS
             }, _Payload},
           {State = #stream_state{state=idle},
            ConnectionState})
when ?IS_FLAG(FH#frame_header.flags, ?FLAG_END_STREAM) ->
    {State#stream_state{
      stream_id = StreamId,
      state = half_closed_remote,
      incoming_frames = [F]
     }, ConnectionState};
%% This one goes to open, because it's a headers frame, but not the
%% end of stream
recv_frame(F={_FH = #frame_header{
              stream_id=StreamId,
              type=?HEADERS
             }, _Payload},
           {State = #stream_state{state=idle},
            ConnectionState}) ->
    {State#stream_state{
      stream_id = StreamId,
      state = open,
      incoming_frames = [F]
     }, ConnectionState};
recv_frame(F={#frame_header{
                 stream_id=StreamId,
                 type=?CONTINUATION
                }, _Payload},
           {State = #stream_state{
                      stream_id=StreamId,
                      incoming_frames=Frames
                     },
            ConnectionState}) ->
    {State#stream_state{
      incoming_frames = [F|Frames]
     }, ConnectionState};

%% When 'open' and stream recv window too small
recv_frame({_FH=#frame_header{
                   length=L,
                   type=?DATA
                  }, _P},
           {S = #stream_state{
                   state=open,
                   stream_id=StreamId,
                   recv_window_size=SRWS
                },
          ConnectionState})
  when L > SRWS ->
    rst_stream(?FLOW_CONTROL_ERROR, StreamId, ConnectionState),
    {S#stream_state{
      state=closed,
      recv_window_size=0,
      incoming_frames=[]
     }, ConnectionState};
%% When 'open' and connection recv window too small
recv_frame({_FH=#frame_header{
                   length=L,
                   type=?DATA
                  }, _P},
           {S = #stream_state{
                 state=open
                },
            ConnectionState=#connection_state{
              recv_window_size=CRWS
             }
           })
  when L > CRWS ->
    http2_connection:go_away(?FLOW_CONTROL_ERROR, ConnectionState),
    {S#stream_state{
      state=closed,
      recv_window_size=0,
      incoming_frames=[]
     }, ConnectionState};
%% Open and not END STREAM
recv_frame(F={_FH=#frame_header{
                   length=L,
                   type=?DATA,
                   flags=Flags
                  }, _P},
          {S = #stream_state{
                  recv_window_size=SRWS,
                  incoming_frames=IF
                 },
           ConnectionState=#connection_state{
             recv_window_size=CRWS
            }
          })
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    {S#stream_state{
      recv_window_size=SRWS-L,
      incoming_frames=IF ++ [F]
     }, ConnectionState#connection_state{
      recv_window_size=CRWS-L
         }
    };
%% Open, DATA, AND END_STREAM
recv_frame(F={_FH=#frame_header{
                   length=L,
                   type=?DATA,
                   flags=Flags
                  }, _P},
          {S = #stream_state{
                  recv_window_size=SRWS,
                  incoming_frames=IF
                 },
           ConnectionState=#connection_state{
             recv_window_size=CRWS
            }
          })
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    {S#stream_state{
      state=half_closed_remote,
      recv_window_size=SRWS-L,
      incoming_frames=IF ++ [F]
     },
     ConnectionState#connection_state{
       recv_window_size=CRWS-L
      }
    };
%% needs a WINDOW_UPDATE clause badly
recv_frame({#frame_header{
               type=?WINDOW_UPDATE,
               stream_id=StreamId
              },
            #window_update{
               window_size_increment=WSI
              }
           },
           {State=#stream_state{
                      stream_id=StreamId,
                      send_window_size=SWS,
                      queued_frames=QF
                     },
            ConnectionState}) ->
    NewSendWindow = WSI + SWS,
    NewState = State#stream_state{
                 send_window_size=NewSendWindow,
                 queued_frames=[]
                },
    lager:info("Stream ~p send window now: ~p", [StreamId, NewSendWindow]),
    lists:foldl(
      fun(Frame, Stream) -> send_frame(Frame, Stream) end,
      {NewState, ConnectionState},
      QF);
recv_frame(_F, {S, C}) ->
    {S, C}.


-spec send_frame(frame(), {stream_state(), connection_state()}) -> {stream_state(), connection_state()}.
send_frame(F={#frame_header{
                 type=?HEADERS
                },_},
           {StreamState = #stream_state{},
            ConnectionState = #connection_state{
                                 socket={Transport,Socket}
                                }
           }) ->
    Transport:send(Socket, http2_frame:to_binary(F)),
    {StreamState, ConnectionState};
send_frame(F={#frame_header{
                 length=L,
                 type=?DATA
                },_Data},
           {StreamState = #stream_state{
                      send_window_size=SSWS
                      },
            ConnectionState = #connection_state{
                                 socket={Transport,Socket},
                                 send_window_size=CSWS
                                }
           })
  when SSWS >= L, CSWS >= L ->
    Transport:send(Socket, http2_frame:to_binary(F)),
    {StreamState#stream_state{
       send_window_size=SSWS-L
      },
     ConnectionState#connection_state{
       send_window_size=CSWS-L
      }
    };
send_frame(F={#frame_header{
                 type=?DATA
                },_Data},
           {StreamState = #stream_state{
                      queued_frames = QF
                     },
           ConnectionState = #connection_state{}}) ->
    {StreamState#stream_state{
       queued_frames=QF ++ [F]
      },
     ConnectionState};
send_frame(F={#frame_header{
                 type=?PUSH_PROMISE
                 }, _Data},
           {StreamState = #stream_state{
                             },
            ConnectionState = #connection_state{
                                 socket={Transport,Socket}
                                }}) ->
    Transport:send(Socket, http2_frame:to_binary(F)),
    {StreamState, ConnectionState};
send_frame(_F, S) ->
    S.

rst_stream(ErrorCode, StreamId, #connection_state{socket={Transport, Socket}}) ->
    RstStream = #rst_stream{error_code=ErrorCode},
    RstStreamBin = http2_frame:to_binary(
                     {#frame_header{
                         stream_id=StreamId
                        },
                      RstStream}),
    Transport:send(Socket, RstStreamBin),
    ok.
