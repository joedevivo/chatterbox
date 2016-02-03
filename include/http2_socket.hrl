
-include_lib("http2.hrl").
-record(http2_socket_state, {
          type           :: client | server,
          socket         :: {gen_tcp, gen_tcp:socket()} | {ssl, ssl:sslsocket()},
          http2_pid      :: pid(),
          buffer = empty :: empty | {binary, binary()} | {frame, frame_header(), binary()}
          }).
