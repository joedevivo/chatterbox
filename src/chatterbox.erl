-module(chatterbox).

-include("http2.hrl").

-export([settings/0]).

settings() ->
    HTS = application:get_env(?MODULE, header_table_size, 4096),
    EP = application:get_env(?MODULE, enable_push, 1),
    MCS = application:get_env(?MODULE, max_concurrent_streams, unlimited),
    IWS = application:get_env(?MODULE, initial_window_size, 65535),
    MFS = application:get_env(?MODULE, max_frame_size, 16834),
    MHLS = application:get_env(?MODULE, max_header_list_size, unlimited),

    #settings{
       header_table_size=HTS,
       enable_push=EP,
       max_concurrent_streams=MCS,
       initial_window_size=IWS,
       max_frame_size=MFS,
       max_header_list_size=MHLS
      }.
