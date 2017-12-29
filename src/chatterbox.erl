-module(chatterbox).

-include("http2.hrl").

-export([
         start/0,
         settings/0,
         settings/1,
         settings/2
        ]).

start() ->
    chatterbox_sup:start_link().

settings() ->
    settings(server).

settings(server, Settings=#{}) ->
    HTS  = maps:get(server_header_table_size, Settings, 4096),
    EP   = maps:get(server_enable_push, Settings, 1),
    MCS  = maps:get(server_max_concurrent_streams, Settings, unlimited),
    IWS  = maps:get(server_initial_window_size, Settings, 65535),
    MFS  = maps:get(server_max_frame_size, Settings, 16384),
    MHLS = maps:get(server_max_header_list_size, Settings, unlimited),
    #settings{
       header_table_size=HTS,
       enable_push=EP,
       max_concurrent_streams=MCS,
       initial_window_size=IWS,
       max_frame_size=MFS,
       max_header_list_size=MHLS
      }.

settings(server) ->
    HTS  = application:get_env(?MODULE, server_header_table_size, 4096),
    EP   = application:get_env(?MODULE, server_enable_push, 1),
    MCS  = application:get_env(?MODULE, server_max_concurrent_streams, unlimited),
    IWS  = application:get_env(?MODULE, server_initial_window_size, 65535),
    MFS  = application:get_env(?MODULE, server_max_frame_size, 16384),
    MHLS = application:get_env(?MODULE, server_max_header_list_size, unlimited),

    #settings{
       header_table_size=HTS,
       enable_push=EP,
       max_concurrent_streams=MCS,
       initial_window_size=IWS,
       max_frame_size=MFS,
       max_header_list_size=MHLS
      };

settings(client) ->
    HTS  = application:get_env(?MODULE, client_header_table_size, 4096),
    EP   = application:get_env(?MODULE, client_enable_push, 1),
    MCS  = application:get_env(?MODULE, client_max_concurrent_streams, unlimited),
    IWS  = application:get_env(?MODULE, client_initial_window_size, 65535),
    MFS  = application:get_env(?MODULE, client_max_frame_size, 16384),
    MHLS = application:get_env(?MODULE, client_max_header_list_size, unlimited),

    #settings{
       header_table_size=HTS,
       enable_push=EP,
       max_concurrent_streams=MCS,
       initial_window_size=IWS,
       max_frame_size=MFS,
       max_header_list_size=MHLS
      }.
