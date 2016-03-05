-module(http2_frame_queue).

-include("http2.hrl").

-export([
         ketchup/3,
         ketchup/4
        ]).

%% We'll need the ability to fold over a queue of frames and for each
%% frame that is smaller than the accumulator connection size, try and
%% send the frame

%% But when not to send frames? Our accumulator will need to maintain
%% a set of stream ids that it has rejected a frame for. Once it has
%% rejected a frame for a stream, all others are rejected, preserving
%% order

-record(accumulator, {
          stream_id = undefined :: undefined | stream_id(),
          blocked_streams = [] :: [stream_id()],
          streams = [] :: [{stream_id(), pid()}],
          connection_recv_window_size = 0 :: non_neg_integer(),
          new_queue = queue:new() :: queue:queue(frame())
}).

%% The baby tomato starts lagging behind...
-spec ketchup(queue:queue(frame()),
              non_neg_integer(),
              [{stream_id(), pid()}])
             ->
                     {queue:queue(frame()), non_neg_integer()}.
ketchup(FrameQueue, ConnectionWindowSize, Streams) ->
    Accumulator =
        #accumulator{
           streams=Streams,
           connection_recv_window_size=ConnectionWindowSize
          },
    Done = ketchup(Accumulator, queue:to_list(FrameQueue)),
    {Done#accumulator.new_queue,
     Done#accumulator.connection_recv_window_size
    }.

-spec ketchup(
        stream_id(),
        queue:queue(frame()),
        non_neg_integer(),
        [{stream_id(), pid()}])
             ->
                     {queue:queue(frame()), non_neg_integer()}.
ketchup(StreamId, FrameQueue, ConnectionWindowSize, Streams) ->
    Accumulator =
        #accumulator{
           stream_id=StreamId,
           streams=Streams,
           connection_recv_window_size=ConnectionWindowSize
          },
    Done = ketchup(Accumulator, queue:to_list(FrameQueue)),
    {Done#accumulator.new_queue,
     Done#accumulator.connection_recv_window_size
    }.

-spec ketchup(#accumulator{}, [frame()]) ->
                     #accumulator{}.
ketchup(Acc, []) ->
    Acc;
ketchup(#accumulator{
           stream_id = WorkingStreamId,
           connection_recv_window_size=CRWS,
           new_queue = NewQ,
           blocked_streams=BlockedStreams,
           streams=Streams
          }=Acc,
        [ {
            #frame_header{
               length=L,
               stream_id=StreamId
              }
          , _}=Frame
          |Tail]) ->

    %lager:info("Acc! ~p", [Acc]),
    %% Block if not the specific stream called, or something added to
    %% the blocked streams list in a previous iteration
    Blocked = lists:member(StreamId, BlockedStreams)
        orelse (WorkingStreamId =/= StreamId andalso WorkingStreamId =/= undefined ),
    lager:info("Blocked = ~p orelse ~p", [lists:member(StreamId, BlockedStreams), WorkingStreamId =/= StreamId]),
    lager:info("{~p, ~p}", [Blocked, L > CRWS]),
    case {Blocked, L > CRWS} of
        {true, _} ->
            % Already blocked, autoskip
            ketchup(
              Acc#accumulator{
                new_queue=queue:in(Frame, NewQ)
               },
              Tail);
        {false, true} ->
            %% This frame can't make it, others might tho
            ketchup(
              Acc#accumulator{
                new_queue=queue:in(Frame, NewQ),
                blocked_streams=[StreamId|BlockedStreams]
               },
              Tail);
        {false, false} ->
            lager:debug("Sending queued frame ~p", [Frame]),
            StreamPid = proplists:get_value(StreamId, Streams),
            Sent = http2_stream:send_frame(StreamPid, Frame),
            case Sent of
                ok ->
                    %% Ok, keep going, don't put this frame on the new_queue,
                    %% modify the acc's window size
                    ketchup(
                      Acc#accumulator{
                        connection_recv_window_size=CRWS-L
                       },
                      Tail);
                flow_control ->
                    %% Couldn't send. blacklist stream
                    ketchup(
                      Acc#accumulator{
                        new_queue=queue:in(Frame, NewQ),
                        blocked_streams=[StreamId|BlockedStreams]
                       },
                      Tail)
            end
    end.
