-module(chatterbox_tests).

-include_lib("eunit/include/eunit.hrl").

chatterbox_test_() ->
    {setup,
     fun() ->
             ok
     end,
     fun(_) ->
             ok
     end,
     [
      {"chatterbox is alive",
       fun() ->
               %% format is always: expected, actual
               ?assertEqual(howdy, chatterbox:hello())
       end}
      ]}.

