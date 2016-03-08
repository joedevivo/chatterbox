-module(http2_stream_SUITE).

-include("http2.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").


-compile([export_all]).

-record(state, {
          stream_pid,
          states = [],
          response_data=[]
         }).

all() ->
    [basic_test].

basic_test(_Config) ->
    proper:quickcheck(prop_http2_streams()).

initial_state() ->
    idle.

initial_state_data() ->
    {ok, Pid} = http2_stream:start_link([
                                         {callback_module, chatterbox_static_stream}
                                        ]),

    ct:pal("g_data_frame() ~p", [g_data_frame()]),
    #state{
       stream_pid = Pid,
       response_data=g_data_frames()
      }.

prop_http2_streams() ->
    ?FORALL(
       Cmds, proper_fsm:commands(?MODULE),
       begin
           {History, State, Result} = proper_fsm:run_commands(?MODULE, Cmds),


           ?WHENFAIL(io:format("History: ~w~nState: ~w\nResult: ~w~n",
                               [History, State, Result]),
                     Result =:= ok)
       end
      ).

idle(#state{
        stream_pid=Pid
       }) ->
    [
%     {reserved_local, {call, http2_stream, send_pp, [Pid, []]}},
%     {reserved_remote, {call, http2_stream, recv_pp, [Pid, []]}},
     {open, {call, http2_stream, send_h, [Pid, []]}},
     {open, {call, http2_stream, recv_h, [Pid, []]}}
    ].

open(#state{
        stream_pid=Pid
       }) ->
    [
     {half_closed_remote, {call, http2_stream, recv_es, [Pid]}}
    ].

half_closed_remote(#state{
                      stream_pid=Pid,
                      response_data=[FinalFrame]
                     }) ->
    [
     {closed, {'call', http2_stream, send_frame, [Pid, FinalFrame]}}
    ];
half_closed_remote(#state{
                      stream_pid=Pid,
                      response_data=[Frame|_Tail]
                     }) ->
    [
     {half_closed_remote, {'$call', http2_stream, send_frame, [Pid, Frame]}}
    ].

closed(#state{}) ->
    [].

precondition(_, _, _, _) ->
    true.

next_state_data(idle, open, State=#state{states=[]}, _,
                {call, http2_stream, X, _}) ->
    State#state{states=[{idle, X}]};
next_state_data(open, half_closed_remote, State=#state{}, _,
               {call, http2_stream, _, _}) ->
    State;
next_state_data(half_closed_remote, half_closed_remote,
                State=#state{
                        response_data=[_Frame|Tail]
                        }, _,
               {call, http2_stream, _, _}) ->
    State#state{response_data=Tail};
next_state_data(half_closed_remote, closed, State=#state{}, _,
               {call, http2_stream, _, _}) ->
    State#state{response_data=[]}.


postcondition(idle, open, #state{}, {call, http2_stream, _, _}, ok) ->
    true;
postcondition(_, _, _, _, _) -> false.

g_data_frames() ->
%    ?LET({non_neg_integer,

    ?LET(Bin, binary(256), http2_frame_data:to_frames(1, Bin, #settings{max_frame_size=16384})).

g_data_frame() ->
    ?LET({Bin, F},
         {binary(256), integer(0,1)},
         {
           #frame_header{
              length=256,
              flags=F
             },
           #data{
              data=Bin
              }}).
