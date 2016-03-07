-module(http2_frame_queue).

-include("http2.hrl").

-export([
         connection_ketchup/3,
         stream_ketchup/4
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
          connection_send_window_size = 0 :: non_neg_integer(),
          new_queue = queue:new() :: queue:queue(frame())
}).

%% The baby tomato starts lagging behind...

%% connection_ketchup/3 is built to scan through a queue of frames to
%% try and send them until the Connection's Send Window Size is 0. The
%% chances of that actually happening are very rare. The reality is
%% that you'll have some connection send window that gets smaller each
%% time you send a frame, and it will be small enough that no frame
%% you have queued will actually fit in it, but it has to check every
%% queued frame to know. There's also some conditional logic that
%% won't try to send a frame if a frame from that stream id has
%% already been skipped. This is so that we don't send frames out of
%% order, in a situation where the last frame on a stream is probably
%% significantly smaller than the ones that came before it.
-spec connection_ketchup(queue:queue(frame()),
                         non_neg_integer(),
                         [{stream_id(), pid()}])
                        ->
                                {queue:queue(frame()), non_neg_integer()}.
connection_ketchup(
  FrameQueue, ConnectionWindowSize, Streams) ->
    Accumulator =
        #accumulator{
           streams=Streams,
           connection_send_window_size=ConnectionWindowSize
          },
    Done = ketchup(Accumulator, queue:to_list(FrameQueue)),
    {Done#accumulator.new_queue,
     Done#accumulator.connection_send_window_size
    }.

%% stream_ketchup/4 is just like connection_ketchup/3, only it only
%% checks frames for one stream id. This is the function we use after
%% receiving a WINDOW_UPDATE frame on a stream id. It's telling us
%% this stream might work now so try it, but we have no reason to
%% believe any other stream has become unblocked, so trying those
%% again would be a waste.
-spec stream_ketchup(
        stream_id(),
        queue:queue(frame()),
        non_neg_integer(),
        [{stream_id(), pid()}])
             ->
                     {queue:queue(frame()), non_neg_integer()}.
stream_ketchup(
  StreamId, FrameQueue, ConnectionWindowSize, Streams) ->
    Accumulator =
        #accumulator{
           stream_id=StreamId,
           streams=Streams,
           connection_send_window_size=ConnectionWindowSize
          },
    Done = ketchup(Accumulator, queue:to_list(FrameQueue)),
    {Done#accumulator.new_queue,
     Done#accumulator.connection_send_window_size
    }.

-spec ketchup(#accumulator{}, [frame()]) ->
                     #accumulator{}.
ketchup(Acc, []) ->
    Acc;
ketchup(#accumulator{
           stream_id = WorkingStreamId,
           connection_send_window_size=CWS,
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

    %% Since the only difference between stream level and connection
    %% level ketchup is when to skip even trying to send a frame, we
    %% solve it with this conditional. If we're on the connection
    %% level, 'WorkingStreamId' is 'undefined', so we check:
    %% * Is the StreamId of this frame in the list of BlockedFrames?
    %% * OR Is WorkingStreamId not equal to this frame's StreamId?
    %%      (But only if WorkingStreamId is not equal to undefined)
    %%      If it is undefined, we're at the connection level,
    %%      so don't bother with this part of the check
    Blocked = lists:member(StreamId, BlockedStreams)
        orelse (WorkingStreamId =/= StreamId andalso WorkingStreamId =/= undefined ),

    case {Blocked, L > CWS} of
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
                        connection_send_window_size=CWS-L
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
