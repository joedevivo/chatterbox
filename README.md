# chatterbox #

Chatterbox is an HTTP/2 library for Erlang. Use as much of it as you
want, but the goal is to implement as much of
[RFC-7540](https://tools.ietf.org/html/rfc7540) as possible, 100% of
the time.

It already pulls in
[joedevivo/hpack](https://github.com/joedevivo/hpack) for the
implementation of [RFC-7541](https://tools.ietf.org/html/rfc7541).

## Rebar3

Chatterbox is a `rebar3` jam. Get into it! rebar3.org

## Setting up Firefox go to the URL `about:config` and search for the
setting `network.http.spdy.enforce.tls.profile` and toggle it to
`false`

## HTTP/2 Connections

Chatterbox provides a module `http2_connection` which models (you
guessed it!) an HTTP/2 connection. This gen_fsm can represent either
side of an HTTP/2 connection (i.e. a client *or* server). Really, the
only difference is in how you start the connection.

### Server Side Connections

A server side connection can be started with
[ninenines/ranch](https://github.com/ninenines/ranch) using the
included `chatterbox_ranch_protocol` like this:

```erlang

%% Set up the socket options:
Options = [
        {port, 8080},
        %% you can find certs to play with in ./config
        {certfile,   "localhost.crt"},
        {keyfile,    "localhost.key"},
        {honor_cipher_order, false},
        {versions, ['tlsv1.2']},
        {next_protocols_advertised, [<<"h2">>]}
],

%% You'll also have to set the content root for the chatterbox static
%% content handler

RootDir = "/path/to/content",

application:set_env(
        chatterbox,
        {chatterbox_static_content_handler, [{root_dir, RootDir}]}),

{ok, _RanchPid} =
    ranch:start_listener(
      chatterbox_ranch_protocol,
      10,
      ranch_ssl,
      Options,
      chatterbox_ranch_protocol,
      []),

```

You can do this in a `rebar3 shell` or in your application.

You don't have to use ranch. You can use see chatterbox_sup for an
alternative.


### Serving up the EUC 2015 Deck

clone chatterbox and [euc2015](https://github.com/joedevivo/euc2015)

then set the `RootDir` above to the checkout of euc2015.

Then it should be as easy as pointing Firefox to
`https://localhost:8080/`.


### Client Side Connections

We'll start up http2_connection a little
differently. `http2_client:start_link/*` will take care of the
differences.

Here's how to use it!

```erlang
{ok, Pid} = http2_client:start_link().

RequestHeaders = [
           {<<":method">>, <<"GET">>},
           {<<":path">>, <<"/index.html">>},
           {<<":scheme">>, <<"http">>},
           {<<":authority">>, <<"localhost:8080">>},
           {<<"accept">>, <<"*/*">>},
           {<<"accept-encoding">>, <<"gzip, deflate">>},
           {<<"user-agent">>, <<"chatterbox-client/0.0.1">>}
          ].

{ok, StreamId} = http2_client:send_request(Pid, RequestHeaders, <<>>).

%% TODO: You might need a timer:sleep in here, as this is kind of a
%% work in progress. Ultimately, this shouldn't be necessary, but it is
%% for now. Sorry

{ok, {ResponseHeaders, ResponseBody}} = http2_client:get_response(Pid, StreamId).

```

There still needs to be some way of detecting that a promise has been
pushed from the server, either actively or passively. In theory, if
you knew the `StreamId`, you could check for a response on that stream
and it would be there.


## Author(s) ##

* Joe DeVivo

## Copyright ##

Copyright (c) 2015,16 Joe DeVivo, dat MIT License tho.
