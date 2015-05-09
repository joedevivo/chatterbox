-module(chatterbox).

-include("http2.hrl").

-export([settings/0]).

settings() ->
    {ok, HTS} = application:get_env(?MODULE, header_table_size),
    {ok, EP} = application:get_env(?MODULE, enable_push),
    {ok, MCS} = application:get_env(?MODULE, max_concurrent_streams),
    {ok, IWS} = application:get_env(?MODULE, initial_window_size),
    {ok, MFS} = application:get_env(?MODULE, max_frame_size),
    {ok, MHLS} = application:get_env(?MODULE, max_header_list_size),

    #settings{
       header_table_size=HTS,
       enable_push=EP,
       max_concurrent_streams=MCS,
       initial_window_size=IWS,
       max_frame_size=MFS,
       max_header_list_size=MHLS
      }.
