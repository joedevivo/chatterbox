# chatterbox #

Chatterbox is an attempt to implement an HTTP/2 compliant sever.

## Setting up Firefox
go to the URL `about:config` and search for the setting `network.http.spdy.enforce.tls.profile` and toggle it to `false`


## Serving up the EUC 2015 Deck

clone chatterbox and [https://github.com/joedevivo/euc2015][euc2015]

Then update [https://github.com/joedevivo/chatterbox/blob/master/config/sys.config#L11] to the path you cloned euc2015 to.

`make rel`

`./_rel/chatterbox/bin/chatterbox console`

It should be as easy as pointing Firefox to `https://localhost:8081/`.

## Author(s) ##

* Joe DeVivo

## Copyright ##

Copyright (c) 2015 Joe DeVivo, dat MIT License tho.
