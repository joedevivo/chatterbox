# chatterbox #

Chatterbox is an attempt to implement an HTTP/2 compliant sever.

All testing is currently done with nghttp & firefox 37

```
nghttp http://localhost:8081 -v
```

## Setting up Firefox
go to the URL `about:config` and search for the setting `network.http.spdy.enforce.tls.profile` and toggle it to `false`


## Author(s) ##

* Joe DeVivo

## Copyright ##

Copyright (c) 2015 Joe DeVivo, dat MIT License tho.
