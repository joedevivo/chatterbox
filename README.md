# chatterbox #

Chatterbox is an attempt to implement an HTTP/2 compliant sever.

## Rebar3

Chatterbox is a `rebar3` jam. Get into it! rebar3.org

## Setting up Firefox go to the URL `about:config` and search for the
setting `network.http.spdy.enforce.tls.profile` and toggle it to
`false`


## Serving up the EUC 2015 Deck

clone chatterbox and [https://github.com/joedevivo/euc2015][euc2015]

Then update
[https://github.com/joedevivo/chatterbox/blob/master/config/sys.config#L11]
to the path you cloned euc2015 to.

`rebar3 release`

` ./_build/default/rel/chatterbox/bin/chatterbox console`

It should be as easy as pointing Firefox to `https://localhost:8081/`.

## An HTTP/2 Client

THIS Is what I meant a client to be. It's still rough, but uses
`http2_connection` now for both client and server, because the same
rules pretty much apply to both.

Make an HTTP/2 request like this:

```erlang
{ok, Pid} = http2_client:start_link().

Headers = [
           {<<":method">>, <<"GET">>},
              {<<":path">>, <<"/index.html">>},
              {<<":scheme">>, <<"http">>},
              {<<":authority">>, <<"localhost:8080">>},
              {<<"accept">>, <<"*/*">>},
              {<<"accept-encoding">>, <<"gzip, deflate">>},
              {<<"user-agent">>, <<"nghttp2/0.7.7">>}
              ].

{ok, StreamId} = http2_client:send_request(Pid, Headers, <<>>).

```

It's still kind of broken, because I'm not processing promises
correctly on the client side but... If it did work, then you could get
the response like this:

```erlang
{ok, {Headers, Body}} = http2_client:get_response(Pid, StreamId).

```


## Author(s) ##

* Joe DeVivo

## Copyright ##

Copyright (c) 2015 Joe DeVivo, dat MIT License tho.
