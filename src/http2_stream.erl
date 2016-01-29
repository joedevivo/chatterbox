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

maybe_decode_request_headers(#stream_state{
                        incoming_frames=IFQ,
                        state=open,
                        request_end_headers=true
                       }=Stream,
                     #connection_state{
                        decode_context=DecodeContext
                        }=Connection) ->
    HeadersBin = http2_frame_headers:from_frames(queue:to_list(IFQ)),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),

    NewStream = Stream#stream_state{
                  incoming_frames=queue:new(),
                  request_headers=Headers
                 },

    NewConnection = Connection#connection_state{
                      decode_context=NewDecodeContext
                     },
    maybe_decode_request_body(NewStream, NewConnection);
maybe_decode_request_headers(Stream, Connection) ->
    {Stream, Connection}.

maybe_decode_request_body(#stream_state{
                             state=open,
                             incoming_frames=IFQ,
                             stream_id=StreamId,
                             request_headers=Headers,
                             request_end_headers=true,
                             request_end_stream=true
                            }=Stream,
                          #connection_state{
                             content_handler=Handler
                            }=Connection) ->
    Data = [ D || {#frame_header{type=?DATA}, #data{data=D}} <- queue:to_list(IFQ)],
    Handler:spawn_handle(self(), StreamId, Headers, Data),
    {Stream#stream_state{
       state=half_closed_remote,
       incoming_frames=queue:new()
      },
     Connection};
maybe_decode_request_body(Stream, Connection) ->
    {Stream, Connection}.

maybe_decode_response_headers(
  #stream_state{
     incoming_frames=IFQ,
     state=half_closed_local,
     response_end_headers=true
    }=Stream,
  #connection_state{
     decode_context=DecodeContext
    }=Connection)->
    HeadersBin = http2_frame_headers:from_frames(queue:to_list(IFQ)),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),
    maybe_decode_response_body(Stream#stream_state{
       incoming_frames=queue:new(),
       response_headers=Headers
      },
     Connection#connection_state{
       decode_context=NewDecodeContext
      });
maybe_decode_response_headers(Stream, Connection) ->
    {Stream, Connection}.

maybe_decode_response_body(
  #stream_state{
     incoming_frames=IFQ,
     response_end_headers=true,
     response_end_stream=true
    }=Stream,
  #connection_state{}=Connection) ->
    Data = [ D || {#frame_header{type=?DATA}, #data{data=D}} <- queue:to_list(IFQ)],
    {Stream#stream_state{
       state=closed,
       incoming_frames=queue:new(),
       response_body = Data
      }, Connection};
maybe_decode_response_body(Stream, Connection) ->
    {Stream, Connection}.

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

%% easiest idle receives HEADERS with END_HEADERS AND END_STREAM!
%% decode headers, handle content, transition to closed
recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    maybe_decode_request_headers(Stream#stream_state{
                           state=open,
                           incoming_frames=queue:in(F,queue:new()),
                           request_end_stream = true,
                           request_end_headers = true
                          }, Connection);


%% idle receives HEADERS with END_STREAM, no END_HEADERS, then transition
%% to open, wait for continuations until END HEADERS,
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
    maybe_decode_request_headers(Stream#stream_state{
                           state=open,
                           request_end_stream=true,
                           incoming_frames=queue:in(F,IFQ)
                          }, Connection);

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?NOT_FLAG(Flags,?FLAG_END_HEADERS) ->
     maybe_decode_request_headers(Stream#stream_state{
                            incoming_frames=queue:in(F,IFQ)
                           }, Connection);

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    maybe_decode_request_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        request_end_headers=true
        }, Connection);

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
            Connection=#connection_state{}})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    maybe_decode_request_headers(
      Stream#stream_state{
        request_end_headers=true,
        incoming_frames=queue:in(F, queue:new())
       },
      Connection);

recv_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      incoming_frames=IFQ,
                      state=open,
                      request_end_headers=true,
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          recv_window_size=CRWS
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       SRWS >= L, CRWS >= L ->
    {Stream#stream_state{
        incoming_frames=queue:in(F,IFQ),
        recv_window_size=SRWS-L
       },
      Connection#connection_state{
        recv_window_size=CRWS-L
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
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SRWS >= L, CRWS >= L ->

    maybe_decode_request_body(
      Stream#stream_state{
        recv_window_size=SRWS-L,
        incoming_frames=queue:in(F, IFQ),
        request_end_stream=true
       },
      Connection#connection_state{
        recv_window_size=CRWS-L
       });

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
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    maybe_decode_request_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        request_end_headers=true
        },
      Connection);

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    maybe_decode_request_headers(
      Stream#stream_state{
        request_end_stream=true,
        request_end_headers=true,
        incoming_frames=queue:in(F, IFQ)
       },
      Connection);

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
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       SRWS >= L, CRWS >= L ->
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
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          recv_window_size=CRWS
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SRWS >= L, CRWS >= L ->
    maybe_decode_request_body(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        recv_window_size=SRWS-L,
        request_end_stream=true
        },
      Connection#connection_state{
        recv_window_size=CRWS-L
       });

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
    lager:debug("Stream ~p send window now: ~p", [StreamId, NewSendWindow]),
    lists:foldl(
      fun(Frame, Stream) -> send_frame(Frame, Stream) end,
      {NewState, ConnectionState},
      queue:to_list(QF));

%% receive server responses

%%Easy, one frame headers, no body
recv_frame(F={#frame_header{
                 flags=Flags,
                 type=?HEADERS
                 },_},
           {#stream_state{
               state=half_closed_local
              }=Stream,
            #connection_state{}=Connection})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    maybe_decode_response_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, queue:new()),
        response_end_headers=true,
        response_end_stream=true
       },
      Connection);

%% half closed local receives HEADERS with END_STREAM, no END_HEADERS,
%% transition to closed, wait for continuations until END HEADERS,
%% then decode headers.
recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_local,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       ?NOT_FLAG(Flags, ?FLAG_END_HEADERS) ->
    maybe_decode_response_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F,IFQ),
        response_end_stream=true
      }, Connection);

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_local,
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
                      state=half_closed_local,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS) ->
    maybe_decode_response_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        response_end_headers=true
       },
      Connection);

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_local
                     },
            Connection=#connection_state{}})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    maybe_decode_response_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, queue:new()),
        response_end_headers=true
       }, Connection);

recv_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      incoming_frames=IFQ,
                      state=half_closed_local,
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          recv_window_size=CRWS
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       SRWS >= L, CRWS >= L ->
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
                      state=half_closed_local,
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          recv_window_size=CRWS
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SRWS >= L, CRWS >= L ->
    maybe_decode_request_body(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        response_end_stream=true,
        recv_window_size=SRWS-L
        },
     Connection#connection_state{
       recv_window_size=CRWS-L
      }
    );

%% idle receives HEADERS, no END_STREAM or END_HEADERS transition into
%% open, expect continuations until one shows up with an END_HEADERS,
%% then expect DATA frames until one shows up with an END_STREAM

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_local,
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
                      state=half_closed_local,
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
                      state=half_closed_local,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    maybe_decode_request_body(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        response_end_headers=true
       }, Connection);

recv_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_local,
                      incoming_frames=IFQ
                     },
            Connection=#connection_state{}})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    maybe_decode_response_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        response_end_headers=true,
        response_end_stream=true
        },
      Connection);

recv_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_local,
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
                      recv_window_size=SRWS
                     },
            Connection=#connection_state{
                          recv_window_size=CRWS
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    maybe_decode_response_body(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        response_end_stream=true,
        recv_window_size=SRWS-L
       },
      Connection#connection_state{
        recv_window_size=CRWS-L
       });

recv_frame(_F, {S, C}) ->
    {S, C}.


%% Dear Friday Bojack,
%% recv_frame seems to work, modify send_frame to work kinda the same and then go back to http2_client

-spec send_frame(frame(), {stream_state(), connection_state()})
                -> {stream_state(), connection_state()}.
%% For sending requests from the idle state. This state machine deals
%% with modeling the HTTP/2 protocol, and this level any actions with
%% the encode context for HPACK should have already occurred. Since
%% we're encoding, the contiunation state on the client side at the
%% connection level can be bypassed because we control message
%% ordering, we don't need the mutex

%% you've sent a headers frame with both the END_HEADERS and
%% END_STREAM flags
send_frame(F={#frame_header{
                 flags=Flags,
                 type=?HEADERS
                },_},
           {StreamState = #stream_state{
                             state=idle
                            },
            ConnectionState = #connection_state{
                                 socket=Socket
                                }
           })
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_STREAM)->
    http2_socket:send(Socket, F),
    {StreamState#stream_state{
       request_end_headers=true,
       request_end_stream=true,
       state=half_closed_local
      }, ConnectionState};

%% you've sent HEADERS with END_STREAM, but you're not done with
%% continuations. WHY?! It's technically possible
send_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       ?NOT_FLAG(Flags, ?FLAG_END_HEADERS) ->
    http2_socket:send(Socket, F),
    {Stream#stream_state{
       request_end_stream=true,
       state=open
      }, Connection};

%% You've sent a CONTINUATION, but no END_HEADERS and you're in the
%% open state from the above clause
send_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?NOT_FLAG(Flags,?FLAG_END_HEADERS) ->
    http2_socket:send(Socket, F),
    {Stream, Connection};

%% Finally, you're in half closed (local) so you already have
%% END_STREAM, and here goes END_HEADERS. You're now just waiting for
%% a resposne.
send_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=half_closed_local
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS) ->
    http2_socket:send(Socket, F),
    {Stream, Connection};


%% idle receives HEADERS with END_HEADERS, no END_STREAM. transition
%% to open and wait for DATA frames until one comes with END_STREAM,
%% then decode headers, handle content and transtition to closed.
send_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    http2_socket:send(Socket, F),
    {Stream#stream_state{
       state=open
      },
     Connection};

send_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      send_window_size=SSWS
                     },
            Connection=#connection_state{
                          send_window_size=CSWS,
                          socket=Socket
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       SSWS >= L, CSWS >= L ->
    http2_socket:send(Socket, F),
    {Stream#stream_state{
       send_window_size=SSWS-L
      },
     Connection#connection_state{
       send_window_size=CSWS-L
      }
    };


send_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      send_window_size=SSWS
                     },
            Connection=#connection_state{
                          send_window_size=CSWS,
                          socket=Socket
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SSWS >= L, CSWS >= L ->
    http2_socket:send(Socket, F),
    NewStream = Stream#stream_state{
                  state=half_closed_remote,
                  send_window_size=SSWS-L
                 },
    {NewStream,
     Connection#connection_state{
       send_window_size=CSWS-L
      }
    };

%% idle receives HEADERS, no END_STREAM or END_HEADERS transition into
%% open, expect continuations until one shows up with an END_HEADERS,
%% then expect DATA frames until one shows up with an END_STREAM

send_frame(F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       ?NOT_FLAG(Flags, ?FLAG_END_HEADERS) ->
    http2_socket:send(Socket, F),
    {Stream#stream_state{
       state=open
      },
     Connection};

send_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?NOT_FLAG(Flags,?FLAG_END_HEADERS),
       ?NOT_FLAG(Flags,?FLAG_END_STREAM)->
    http2_socket:send(Socket, F),
    {Stream, Connection};

send_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?NOT_FLAG(Flags, ?FLAG_END_STREAM) ->
    http2_socket:send(Socket, F),
    {Stream, Connection};

send_frame(F={#frame_header{
                   flags=Flags,
                   type=?CONTINUATION
                  }, _Payload},
           {Stream=#stream_state{
                      state=open
                     },
            Connection=#connection_state{
                          socket=Socket
                         }})
  when ?IS_FLAG(Flags,?FLAG_END_HEADERS),
       ?IS_FLAG(Flags, ?FLAG_END_STREAM) ->
    http2_socket:send(Socket, F),

    NewStream = Stream#stream_state{
                  state=half_closed_local
                 },
    {NewStream, Connection};

send_frame(F={#frame_header{
                   length=L,
                   flags=Flags,
                   type=?DATA
                  }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      send_window_size=SSWS
                     },
            Connection=#connection_state{
                          send_window_size=CSWS,
                          socket=Socket
                         }})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       SSWS >= L, CSWS >= L ->
    http2_socket:send(Socket, F),
    {Stream#stream_state{
       send_window_size=SSWS-L
      },
     Connection#connection_state{
       send_window_size=CSWS-L
      }
    };

send_frame(F={#frame_header{
                 length=L,
                 flags=Flags,
                 type=?DATA
                }, _Payload},
           {Stream=#stream_state{
                      state=open,
                      send_window_size=SSWS
                     },
            Connection=#connection_state{
                          socket=Socket,
                          send_window_size=CSWS
                         }})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SSWS >= L, CSWS >= L ->
    http2_socket:send(Socket, F),
    NewStream = Stream#stream_state{
                  state=half_closed_local,
                  send_window_size=SSWS-L
                 },
    {NewStream,
     Connection#connection_state{
        send_window_size=CSWS-L
      }
    };
send_frame(F={#frame_header{
                 type=?DATA
                },_Data},
           {StreamState = #stream_state{
                      queued_frames = QF,
                      state=open
                     },
           ConnectionState = #connection_state{}}) ->
    %% TODO: Build and send a WINDOW_UPDATE request
    {StreamState#stream_state{
       queued_frames=queue:in(F,QF)
      },
     ConnectionState};

%% For sending responses in the half closed (remote) state
send_frame(F={#frame_header{
                 type=?HEADERS
                },_},
           {StreamState = #stream_state{
                             state=half_closed_remote
                            },
            ConnectionState = #connection_state{
                                 socket=Socket
                                }
           }) ->
    http2_socket:send(Socket, F),
    {StreamState, ConnectionState};
%% TODO: Can't handle sending CONTINUATION frames in a response
send_frame(F={#frame_header{
                 length=L,
                 type=?DATA
                },_Data},
           {StreamState = #stream_state{
                      send_window_size=SSWS,
                      state=half_closed_remote
                      },
            ConnectionState = #connection_state{
                                 socket=Socket,
                                 send_window_size=CSWS
                                }
           })
  when SSWS >= L, CSWS >= L ->
    http2_socket:send(Socket, F),
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
                      queued_frames = QF,
                      state=half_closed_remote
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
                             state=idle
                             },
            ConnectionState = #connection_state{
                                 socket=Socket,
                                 recv_settings=#settings{initial_window_size=RecvWindowSize},
                                 send_settings=#settings{initial_window_size=SendWindowSize},
                                 streams=Streams
                                }}) ->
    http2_socket:send(Socket, http2_frame:to_binary(F)),
    NewStream = new(PSID, {SendWindowSize, RecvWindowSize}, reserved_local),

    {StreamState, ConnectionState#connection_state{
                    streams=[NewStream|Streams]
                   }};
send_frame(_F, S) ->
    S.

rst_stream(ErrorCode, StreamId, #connection_state{socket=Socket}) ->
    RstStream = #rst_stream{error_code=ErrorCode},
    RstStreamBin = http2_frame:to_binary(
                     {#frame_header{
                         stream_id=StreamId
                        },
                      RstStream}),
    http2_socket:send(Socket, RstStreamBin),
    ok.
