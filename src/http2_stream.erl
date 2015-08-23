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
%% Errors first, since they're usually easier to detect.

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
      incoming_frames=queue:new()
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
      incoming_frames=queue:new()
     }, ConnectionState};

%% So many possibilities:

%% easiest idle receives HEADERS with END_HEADERS AND END_STREAM! decode headers, handle content, transition to closed
recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle
                     },
            Connection=#connection_state{
              decode_context=DecodeContext,
              content_handler=Handler
             }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    HeadersBin = http2_frame_headers:from_frames([F]),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),
    Handler:handle(
      Connection#connection_state{
        decode_context=NewDecodeContext
       },
      Headers,
      Stream#stream_state{
        request_headers=Headers
       });

%% idle receives HEADERS with END_STREAM, no END_HEADERS, transition
%% to half_closed_remote, wait for continuations until END HEADERS,
%% then decode headers, handle content, transition to closed.
recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       ?NOT_FLAG(Flags, ?FLAG_END_HEADERS) ->
    {Stream#stream_state{
       state=half_closed_remote,
       incoming_frames=queue:in(F,IFQ)
      }, Connection};

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_remote,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?NOT_FLAG(Flags,?FLAG_END_HEADERS) ->
    {Stream#stream_state{
       incoming_frames=queue:in(F,IFQ)
      }, Connection};

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_remote,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{
                          decode_context=DecodeContext,
                          content_handler=Handler
                         }})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS) ->
    NewIFQ = queue:in(F, IFQ),

    HeadersBin = http2_frame_headers:from_frames(queue:to_list(NewIFQ)),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),

    NewStream = Stream#stream_state{
                  incoming_frames=queue:new(),
                  request_headers=Headers
                 },

    Handler:handle(
      Connection#connection_state{
        decode_context=NewDecodeContext
       },
      Headers,
      NewStream);

%% idle receives HEADERS with END_HEADERS, no END_STREAM. transition
%% to open and wait for DATA frames until one comes with END_STREAM,
%% then decode headers, handle content and transtition to closed.
recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle
                     },
            Connection=#connection_state{
              decode_context=DecodeContext
             }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    HeadersBin = http2_frame_headers:from_frames([F]),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),
    {Stream#stream_state{
       state=open,
       request_headers=Headers
      },
     Connection#connection_state{
       decode_context=NewDecodeContext
      }};

recv_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      incoming_frames=IFQ,
                      state=open,
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          recv_window_size=CRWS
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->

    {Stream#stream_state{
       incoming_frames=queue:in(F,IFQ),
       recv_window_size=SRWS-L
      },
     Connection#connection_state{
       recv_window_size=CRWS-L
      }
    };


recv_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      incoming_frames=IFQ,
                      state=open,
                      request_headers=Headers,
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          content_handler=Handler,
                          recv_window_size=CRWS
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    NewDataQueue = queue:in(F, IFQ),

    DataFrames = queue:to_list(NewDataQueue),
    lager:debug("Data frames: ~p", [DataFrames]),

    NewStream = Stream#stream_state{
                  incoming_frames=queue:new(),
                  state=half_closed_remote,
                  recv_window_size=SRWS-L
                 },

    Handler:handle(
      Connection#connection_state{
        recv_window_size=CRWS-L
       },
      Headers,
      NewStream);

%% idle receives HEADERS, no END_STREAM or END_HEADERS transition into
%% open, expect continuations until one shows up with an END_HEADERS,
%% then expect DATA frames until one shows up with an END_STREAM

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       ?NOT_FLAG(Flags, ?FLAG_END_HEADERS) ->

    {Stream#stream_state{
       incoming_frames=queue:in(F, IFQ),
       state=open
      },
     Connection};


recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?NOT_FLAG(Flags,?FLAG_END_HEADERS),
       ?NOT_FLAG(Flags,?FLAG_END_STREAM)->
    {Stream#stream_state{
       incoming_frames=queue:in(F,IFQ)
      }, Connection};

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{
                          decode_context=DecodeContext
                         }})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    NewIFQ = queue:in(F, IFQ),

    HeadersBin = http2_frame_headers:from_frames(queue:to_list(NewIFQ)),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),

    {Stream#stream_state{
       incoming_frames=queue:new(),
       request_headers=Headers
      },
     Connection#connection_state{
       decode_context=NewDecodeContext
      }};


recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{
                          decode_context=DecodeContext,
                          content_handler=Handler
                         }})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    NewIFQ = queue:in(F, IFQ),

    HeadersBin = http2_frame_headers:from_frames(queue:to_list(NewIFQ)),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),

    NewStream = Stream#stream_state{
       incoming_frames=queue:new(),
       request_headers=Headers
     },

    Handler:handle(
      Connection#connection_state{
        decode_context=NewDecodeContext
       },
      Headers,
      NewStream);


recv_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ,
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          recv_window_size=CRWS
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    {Stream#stream_state{
       incoming_frames=queue:in(F, IFQ),
       recv_window_size=SRWS-L
      },
     Connection#connection_state{
       recv_window_size=CRWS-L
      }
    };

recv_frame(F={#frame_header{
                 length=L,
                 flags=Flags,
                 type=?DATA
                }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ,
                      request_headers=Headers,
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          content_handler=Handler,
                          recv_window_size=CRWS
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    NewDataQueue = queue:in(F, IFQ),
    DataFrames = queue:to_list(NewDataQueue),
    lager:debug("Data frames: ~p", [DataFrames]),

    NewStream = Stream#stream_state{
                  incoming_frames=queue:new(),
                  state=half_closed_remote,
                  recv_window_size=SRWS-L
                 },

    Handler:handle(
      Connection#connection_state{
        recv_window_size=CRWS-L
       },
      Headers,
      NewStream);


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
                 queued_frames=queue:new()
                },
    lager:info("Stream ~p send window now: ~p", [StreamId, NewSendWindow]),
    lists:foldl(
      fun(Frame, Stream) -> send_frame(Frame, Stream) end,
      {NewState, ConnectionState},
      queue:to_list(QF));
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
       queued_frames=queue:in(F,QF)
      },
     ConnectionState};
send_frame(F={#frame_header{
                 type=?PUSH_PROMISE
                 }, #push_promise{
                       promised_stream_id=PSID
                      }},
           {StreamState = #stream_state{
                             },
            ConnectionState = #connection_state{
                                 socket={Transport,Socket},
                                 recv_settings=#settings{initial_window_size=RecvWindowSize},
                                 send_settings=#settings{initial_window_size=SendWindowSize},
                                 streams=Streams
                                }}) ->
    Transport:send(Socket, http2_frame:to_binary(F)),
    NewStream = new(PSID, {SendWindowSize, RecvWindowSize}, reserved_local),

    {StreamState, ConnectionState#connection_state{
                    streams=[NewStream|Streams]
                   }};
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
