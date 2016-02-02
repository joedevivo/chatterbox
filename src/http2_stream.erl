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

%% This module was a mess because I tried to order clauses in a
%% logical flow, so you could follow a set of function clauses through
%% a particular flow of this fsm. The problem with that is for a human
%% developer, it makes it hard to visualize the fsm. Hopefully this
%% process function will clear things up

%% There are two things that affect state transitions here. "What"
%% we're doing (send|recv) and what we're doing it to
%% (frame()). Previously I had this as two functions: send_frame/2 and
%% recv_frame/2. Those will still exist in some capacity.

-spec process( send|recv,
              frame(),
              {stream_state(), connection_state()}) ->
                     {stream_state(), connection_state()}.

%% IMPORTANT: If we're in an idle state, we can only send/receive
%% HEADERS frames. The diagram in the spec wants you believe that you
%% can send or receive PUSH_PROMISES too, but that's a LIE. What you
%% can do is send PPs from the open or half_closed_remote state, or
%% receive them in the open or half_closed_local state. Then, that
%% will create a new stream in the idle state and THAT stream can
%% transition to one of the reserved states, but you'll never get a
%% PUSH_PROMISE frame with that Stream Id.

%% Since this module is about what to do when we send or receive a
%% frame, we're going to say that if we send or receive a frame on the
%% idle state, it had better be a HEADERS or CONTINUATION frame. When
%% we send/recv PPs on another stream, we'll initialize it in such a
%% way that it's ready to accept CONTIUNATION frames, or it's already
%% transitioned to reserved.

%% If we're in an idle state and have received a HEADERS frame then we
%% will remain idle until a CONTINUATION arrives with an END_HEADERS
%% flag. The same logic applies to PUSH_PROMISE, but we'll never
%% receive a push promise frame on an idle stream.
process(recv, F={#frame_header{
                   flags=Flags,
                   type=?HEADERS
                  }, _Payload},
           {Stream=#stream_state{
                      state=idle
                     },
            Connection=#connection_state{}}) ->
    maybe_decode_request_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F,queue:new()),
        request_end_stream = ?IS_FLAG(Flags, ?FLAG_END_STREAM),
        request_end_headers = ?IS_FLAG(Flags, ?FLAG_END_HEADERS),
        next_state = open
       }, Connection);

%% CONTINUATIONs of a PUSH_PROMISE will be sent on the stream they
%% originated on, not the stream they created. If
%% stream_state.state=idle, they must be headers.
process(recv, F={#frame_header{
                    type=?CONTINUATION,
                    flags=Flags
                    },_},
        {#stream_state{
            incoming_frames=IFQ,
            state=idle,
            request_end_headers=false
           }=Stream,
         #connection_state{}=Connection}) ->
    maybe_decode_request_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        request_end_headers = ?IS_FLAG(Flags, ?FLAG_END_HEADERS)
       },
      Connection);

%% Now for the other half, sending
process(send, F={#frame_header{
                 flags=Flags,
                 type=?HEADERS
                },_},
           {StreamState = #stream_state{
                             state=idle
                            },
            ConnectionState = #connection_state{
                                 socket=Socket
                                }
           }) ->
    %% We're not going to store headers we sent, so just send them and
    %% move on
    http2_socket:send(Socket, F),

    EndStream = ?IS_FLAG(Flags, ?FLAG_END_STREAM),
    EndHeaders = ?IS_FLAG(Flags, ?FLAG_END_HEADERS),

    %% This condition is convered by the maybe_decode_request_*
    %% functions when we're receiving, but when we're sending we don't
    %% need to decode anything
    NewStateName =
        case {EndStream, EndHeaders} of
            {true, true} ->
                half_closed_local;
            _ ->
                open
        end,

    {StreamState#stream_state{
       request_end_headers=EndHeaders,
       request_end_stream=EndStream,
       state=NewStateName
      }, ConnectionState};

process(send, F={#frame_header{
                    flags=Flags,
                    type=?CONTINUATION
                   },_},
        {#stream_state{
            request_end_headers=false,
            request_end_stream=EndStream,
            state=idle
           }=Stream,
         #connection_state{
            socket=Socket
           }=Connection}) ->
    http2_socket:send(Socket, F),

    EndHeaders = ?IS_FLAG(Flags, ?FLAG_END_HEADERS),

    NextState =
        case {EndStream, EndHeaders} of
            {true, true} ->
                half_closed_local;
            {false, true} ->
                open;
            {_, false} ->
                idle
        end,

    {Stream#stream_state{
       request_end_stream=EndStream,
       request_end_headers=EndHeaders,
       state=NextState
      },
     Connection};
%% Done with idle. Those are all the ways out. Which means we've
%% covered all the ways an incoming HEADERS or PUSH_PROMISE is handled


%% PUSH_PROMISES can only be received by streams in the open or
%% half_closed_local, but will create a new stream in the idle state,
%% but that stream may be ready to transition, it'll make sense, I
%% hope! I'd have preferred to put this down where we deal with the
%% open/half_closed states, but I want you to read this first, so you
%% understand what the recv CONTINUATION clause is doing.
process(recv, F={#frame_header{
                   flags=Flags,
                   type=?PUSH_PROMISE
                  },#push_promise{
                       promised_stream_id=PSID
                      }},
           {Stream=#stream_state{
                      state=State
                     },
            Connection=#connection_state{
                          recv_settings=#settings{initial_window_size=RecvWindowSize},
                          send_settings=#settings{initial_window_size=SendWindowSize},
                          streams=Streams
                         }})
  when State =:= open;
       State =:= half_closed_local ->

    lager:debug("OMG Promise: ~p", [PSID]),

    %% Create the promised stream
    NewStream = new(PSID, {SendWindowSize, RecvWindowSize}),
    EndHeaders = ?IS_FLAG(Flags, ?FLAG_END_HEADERS),
    lager:debug("Promise ~p End? ~p", [PSID, EndHeaders]),
    NewerStream =
        NewStream#stream_state{
          incoming_frames=queue:in(F,queue:new()),
          request_end_stream = true,
          request_end_headers = EndHeaders,
          next_state = reserved_remote
         },

    lager:debug("Newer: ~p", [NewerStream]),
    {PromisedStream, NewConnection} =
        maybe_decode_request_headers(
          NewerStream,
          Connection),
    lager:debug("Promised: ~p", [PromisedStream]),



    case EndHeaders of
        true ->
            %% We're returning the stream UNCHANGED! only adding the Promised
            %% Stream to the connection, NewConnection may have an updated
            %% hpack decode context, otherwise, it's unchanged too.
            {Stream,
             NewConnection#connection_state{
               streams=[{PSID, PromisedStream}|Streams]
              }};
        false ->
            %% If we're not done with the headers, keep this stream in
            %% a working space instead of adding it to the connection
            {Stream#stream_state{
               promised_stream = NewStream
              },
             NewConnection}
    end;

%% We also have to account for CONTINUATIONs that are following PPs.
process(recv, F={#frame_header{
                    flags=Flags,
                    type=?CONTINUATION
                   }, _},
        {#stream_state{
            state=State,
            promised_stream=PromisedStream
           }=Stream,
         #connection_state{
            streams=Streams
           }=Connection})
  when State =:= open;
       State =:= half_closed_local ->

    EndHeaders = ?IS_FLAG(Flags, ?FLAG_END_HEADERS),
    NewPromise =
        PromisedStream#stream_state{
          promised_stream=undefined,
          incoming_frames=queue:in(F, PromisedStream#stream_state.incoming_frames),
          request_end_headers=EndHeaders
         },

    {Promise, NewConnection} = maybe_decode_request_headers(NewPromise, Connection),

    case EndHeaders of
        true ->
            {Stream,
             NewConnection#connection_state{
               streams=[{Promise#stream_state.stream_id, Promise}|Streams]
               }};
        false ->
            {Stream#stream_state{
               promised_stream=Promise
               },
             NewConnection}
    end;

%% Sending a PP is the same thing as receiving. We can only send in
%% the open or half_closed_remote states, but it creates a new stream
%% in the idle state
process(send,
        F={#frame_header{
              type=?PUSH_PROMISE,
              flags=Flags
             }, #push_promise{
                   promised_stream_id=PSID
                  }},
        {#stream_state{
            state=State
           }=Stream,
         #connection_state{
            socket=Socket,
%            recv_settings=#settings{initial_window_size=RecvWindowSize},
%            send_settings=#settings{initial_window_size=SendWindowSize},
            streams=Streams
           }=Connection})
  when State =:= open;
       State =:= half_closed_remote ->

    lager:debug("Send Promise ~p -> ~p", [Stream#stream_state.stream_id, PSID]),
    %% ok, we have to send it.
    http2_socket:send(Socket, http2_frame:to_binary(F)),

    EndHeaders = ?IS_FLAG(Flags, ?FLAG_END_HEADERS),

    %% Now we need to construct the promised stream
    {NewStream, StreamTail} = http2_connection:get_stream(PSID, Streams),%  new(PSID, {SendWindowSize, RecvWindowSize}),

    NewerStream =
        NewStream#stream_state{
          request_end_stream=true,
          request_end_headers=EndHeaders,
          next_state=reserved_local
         },

    case EndHeaders of
        true ->
            PromisedStream =
                NewerStream#stream_state{
                  state=reserved_local
                 },
            {Stream,
             Connection#connection_state{
               streams=[{PSID, PromisedStream}|StreamTail]
              }};
        false ->
            {Stream#stream_state{
               promised_stream=NewerStream
               },
             Connection#connection_state{
               streams=StreamTail
              }}
    end;
process(send,
        F={#frame_header{
              type=?CONTINUATION,
              flags=Flags
              },_},
        {#stream_state{
            state=State,
            promised_stream=PromisedStream
           }=Stream,
         #connection_state{
            socket=Socket,
            streams=Streams
           }=Connection})
  when State =:= open;
       State =:= half_closed_remote ->
    http2_socket:send(Socket, F),
    EndHeaders = ?IS_FLAG(Flags, ?FLAG_END_HEADERS),

    NewPromise =
        PromisedStream#stream_state{
          promised_stream=undefined,
          request_end_headers=EndHeaders
         },

    case EndHeaders of
        true ->
            Promise =
                NewPromise#stream_state{
                  state=reserved_local
                 },
            {Stream,
             Connection#connection_state{
               streams=[{Promise#stream_state.stream_id, Promise}|Streams]
              }};
        false ->
            {Stream#stream_state{
               promised_stream=NewPromise
               }, Connection}
    end;

%% In theory, this handles PUSH_PROMISES. This never worked with PPs
%% that had CONTINUATIONs, nor did it it handle recv, so the above
%% block may need work.

process(send,
        F={#frame_header{
            flags=Flags,
            type=?HEADERS
           }, _},
        {#stream_state{
            state=reserved_local
           }=Stream,
         #connection_state{
            socket=Socket
           }=Connection})
  when ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
    http2_socket:send(Socket, F),
    {Stream#stream_state{
       response_end_headers=true,
       state=half_closed_remote
      },
     Connection};

%process(recv,
%        {#frame_header{
%            flags=Flags,
%            type=?HEADERS
%           }, _},
%        {#stream_state{
%            state=reserved_remote
%           }=Stream,
%         #connection_state{}=Connection})
%  when ?IS_FLAG(Flags, ?FLAG_END_HEADERS) ->
%    maybe_decode_response_headers(Stream, Connection);
%    {Stream#stream_state{
%       response_end_headers=true,
%       state=half_closed_remote
%      },
%     Connection};

%% Let's work on 'open' now. If we're open, we've gotten the headers,
%% let's work data:

process(recv,
        F={#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
             },_},
        {#stream_state{
            state=open,
            incoming_frames=IFQ,
            recv_window_size=SRWS
           }=Stream,
         #connection_state{
            recv_window_size=CRWS
           }=Connection})
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
process(recv,
        F={#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
             }, _Payload},
        {#stream_state{
            state=open,
            incoming_frames=IFQ,
            recv_window_size=SRWS
           }=Stream,
         #connection_state{
            recv_window_size=CRWS
           }=Connection})
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
process(recv,
        {#frame_header{
            type=?WINDOW_UPDATE,
            stream_id=StreamId
           },
         #window_update{
            window_size_increment=WSI
           }
        },
        {#stream_state{
            stream_id=StreamId,
            send_window_size=SWS,
            queued_frames=QF
           }=Stream,
         Connection}) ->
    NewSendWindow = WSI + SWS,
    NewStream = Stream#stream_state{
                 send_window_size=NewSendWindow,
                 queued_frames=queue:new()
                },
    lager:debug("Stream ~p send window now: ~p", [StreamId, NewSendWindow]),
    lists:foldl(
      fun(Frame, S) -> send_frame(Frame, S) end,
      {NewStream, Connection},
      queue:to_list(QF));

process(send,
        F={#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
             }, _Payload},
        {#stream_state{
            state=State,
            send_window_size=SSWS
           }=Stream,
         #connection_state{
            send_window_size=CSWS,
            socket=Socket
           }=Connection})
  when ?NOT_FLAG(Flags, ?FLAG_END_STREAM),
       SSWS >= L, CSWS >= L,
       State =:= open orelse State =:= half_closed_remote ->
    http2_socket:send(Socket, F),
    {Stream#stream_state{
       send_window_size=SSWS-L
      },
     Connection#connection_state{
       send_window_size=CSWS-L
      }
    };

process(send,
        F={#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
             }, _Payload},
        {#stream_state{
            state=State,
            send_window_size=SSWS
           }=Stream,
         #connection_state{
            send_window_size=CSWS,
            socket=Socket
           }=Connection})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SSWS >= L, CSWS >= L,
       State =:= open orelse State =:= half_closed_remote ->
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

%% half_closed_local, can only receive

process(recv,
        F={#frame_header{
              type=?HEADERS,
              flags=Flags
             },_},
        {#stream_state{
            state=half_closed_local
           }=Stream,
         #connection_state{
           }=Connection}) ->
    maybe_decode_response_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F,queue:new()),
        response_end_stream = ?IS_FLAG(Flags, ?FLAG_END_STREAM),
        response_end_headers = ?IS_FLAG(Flags, ?FLAG_END_HEADERS)
       }, Connection);

process(recv, F={#frame_header{
                    type=?CONTINUATION,
                    flags=Flags
                    },_},
        {#stream_state{
            incoming_frames=IFQ,
            state=half_closed_local,
            response_end_headers=false
           }=Stream,
         #connection_state{}=Connection}) ->
    maybe_decode_response_headers(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        response_end_headers = ?IS_FLAG(Flags, ?FLAG_END_HEADERS)
       },
      Connection);

process(recv,
        F={#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
             },_},
        {#stream_state{
            state=half_closed_local,
            incoming_frames=IFQ,
            recv_window_size=SRWS
           }=Stream,
         #connection_state{
            recv_window_size=CRWS
           }=Connection})
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
process(recv,
        F={#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
             }, _Payload},
        {#stream_state{
            state=half_closed_local,
            incoming_frames=IFQ,
            recv_window_size=SRWS
           }=Stream,
         #connection_state{
            recv_window_size=CRWS
           }=Connection})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SRWS >= L, CRWS >= L ->
    maybe_decode_response_body(
      Stream#stream_state{
        incoming_frames=queue:in(F, IFQ),
        recv_window_size=SRWS-L,
        response_end_stream=true
       },
      Connection#connection_state{
        recv_window_size=CRWS-L
        });

%% half_closed_remote: We can send things, we just won't receive
process(send,
        F={#frame_header{
              type=Type,
              flags=Flags
              }, _},
        {#stream_state{
            state=half_closed_remote
            }=Stream,
         #connection_state{
            socket=Socket
           }=Connection})
  when Type =:= ?HEADERS;
       Type =:= ?CONTINUATION ->
    http2_socket:send(Socket, F),
    case ?IS_FLAG(Flags, ?FLAG_END_STREAM) of
        true ->
            {Stream#stream_state{state=closed},
             Connection};
        false ->
            {Stream, Connection}
    end;

process(send,
        F={#frame_header{
              length=L,
              flags=Flags,
              type=?DATA
             }, _Payload},
        {#stream_state{
            state=half_closed_remote,
            send_window_size=SSWS
           }=Stream,
         #connection_state{
            send_window_size=CSWS,
            socket=Socket
           }=Connection})
  when ?IS_FLAG(Flags, ?FLAG_END_STREAM),
       SSWS >= L, CSWS >= L ->
    http2_socket:send(Socket, F),
    NewStream = Stream#stream_state{
                  state=closed,
                  send_window_size=SSWS-L
                 },
    {NewStream,
     Connection#connection_state{
       send_window_size=CSWS-L
      }
    };


%% TODO: ???
process(A, B, C) ->
    lager:error("No process/3 for ~p, ~p, ~p", [A,B,C]),
    C.


maybe_decode_request_headers(
  #stream_state{
     incoming_frames=IFQ,
     state=idle,
     request_end_headers=true,
     next_state=NextStateName
    }=Stream,
  #connection_state{
     decode_context=DecodeContext
    }=Connection) ->
    HeadersBin = http2_frame_headers:from_frames(queue:to_list(IFQ)),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),

    NewStream = Stream#stream_state{
                  state=NextStateName,
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
                             state=Type,
                             incoming_frames=IFQ,
                             stream_id=StreamId,
                             request_headers=Headers,
                             request_end_headers=true,
                             request_end_stream=true
                            }=Stream,
                          #connection_state{
                             content_handler=Handler
                            }=Connection)
  when Type =:= open;
       Type =:= reserved_remote ->
    Data = [ D || {#frame_header{type=?DATA}, #data{data=D}} <- queue:to_list(IFQ)],

    Next =
        case Type of
            open ->
                Handler:spawn_handle(self(), StreamId, Headers, Data),
                half_closed_remote;
            _ ->
                reserved_remote
        end,
    {Stream#stream_state{
       state=Next,
       incoming_frames=queue:new()
      },
     Connection};
maybe_decode_request_body(Stream, Connection) ->
    lager:info("Not time to decode request body: ~p", [Stream]),
    {Stream, Connection}.

-spec maybe_decode_response_headers(stream_state(), connection_state()) ->
                                           {stream_state(), connection_state()}.
maybe_decode_response_headers(
  #stream_state{
     incoming_frames=IFQ,
     state=Type,
     response_end_headers=true
    }=Stream,
  #connection_state{
     decode_context=DecodeContext
    }=Connection)
  when Type =:= half_closed_local;
       Type =:= reserved_remote->
    HeadersBin = http2_frame_headers:from_frames(queue:to_list(IFQ)),
    {Headers, NewDecodeContext} = hpack:decode(HeadersBin, DecodeContext),
    maybe_decode_response_body(Stream#stream_state{
       incoming_frames=queue:new(),
       response_headers=Headers,
       state=half_closed_local
      },
     Connection#connection_state{
       decode_context=NewDecodeContext
      });
maybe_decode_response_headers(Stream, Connection) ->
    {Stream, Connection}.

maybe_decode_response_body(
  #stream_state{
     incoming_frames=IFQ,
     state=half_closed_local,
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

recv_frame(F, {S,_C}=Acc) ->
    lager:debug("RecvF: ~p", [F]),
    lager:debug("RecvS: ~p", [S]),
    process(recv, F, Acc).

-spec send_frame(frame(), {stream_state(), connection_state()})
                -> {stream_state(), connection_state()}.

send_frame({#frame_header{
               length=L,
               type=?DATA},_},
           {#stream_state{
               stream_id=StreamId,
               send_window_size=SSWS
              } = Stream,
            #connection_state{
               send_window_size=CSWS
              }=Connection})
  when L > SSWS; L > CSWS ->
    rst_stream(?FLOW_CONTROL_ERROR, StreamId, Connection),
    {Stream, Connection};

send_frame(F, {S,_C}=Acc) ->
    lager:debug("SendF: ~p", [F]),
    lager:debug("SendS: ~p", [S]),
    process(send, F, Acc).

rst_stream(ErrorCode, StreamId, #connection_state{socket=Socket}) ->
    RstStream = #rst_stream{error_code=ErrorCode},
    RstStreamBin = http2_frame:to_binary(
                     {#frame_header{
                         stream_id=StreamId
                        },
                      RstStream}),
    http2_socket:send(Socket, RstStreamBin),
    ok.
