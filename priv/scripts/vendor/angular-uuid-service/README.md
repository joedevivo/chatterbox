# angular-uuid-service
[![Build Status][build-image]][build-url]
[![Code GPA][gpa-image]][gpa-url]
[![Test Coverage][coverage-image]][coverage-url]
[![Dependency Status][depstat-image]][depstat-url]
[![Bower Version][bower-image]][bower-url]
[![NPM version][npm-image]][npm-url]
[![IRC Channel][irc-image]][irc-url]
[![Gitter][gitter-image]][gitter-url]

## About

This project is a tiny (196 byte) standalone AngularJS UUID/GUID generator service that is RFC4122 version 4 compliant.

## Example

To use the service create something with `uuid` as a dependency then call the `rfc4122.v4()` service.

```javascript
angular.module('demo', ['uuid'])
.directive('uuid', ['rfc4122', function (rfc4122) {
  return function (scope, elm) {
    elm.text(rfc4122.v4());
  };
}]);
```

Sample directive shows the new UUID/GUID ([live example](http://jsfiddle.net/daniellmb/Ppdq5/))

```html
<div ng-app="demo">
    <div uuid></div>
    <div uuid></div>
    <div uuid></div>
    <div uuid></div>
    <div uuid></div>
    <div uuid></div>
    <div uuid></div>
    <div uuid></div>
</div>
```

## Install Choices
- `bower install angular-uuid-service`
- [download the zip](https://github.com/daniellmb/angular-uuid-service/archive/master.zip)

## Tasks

All tasks can be run by simply running `gulp` or with the `npm test` command, or individually:

  * `gulp lint` will lint source code for syntax errors and anti-patterns.
  * `gulp gpa` will analyze source code against complexity thresholds.
  * `gulp test` will run the jasmine unit tests against the source code.
  * `gulp test-min` will run the jasmine unit tests against the minified code.

## License

(The MIT License)

Copyright (c) 2014 Daniel Lamb dlamb.open.source@gmail.com

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
'Software'), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.



[build-url]: https://travis-ci.org/daniellmb/angular-uuid-service
[build-image]: http://img.shields.io/travis/daniellmb/angular-uuid-service.png

[gpa-url]: https://codeclimate.com/github/daniellmb/angular-uuid-service
[gpa-image]: https://codeclimate.com/github/daniellmb/angular-uuid-service.png

[coverage-url]: https://codeclimate.com/github/daniellmb/angular-uuid-service/code?sort=covered_percent&sort_direction=desc
[coverage-image]: https://codeclimate.com/github/daniellmb/angular-uuid-service/coverage.png

[depstat-url]: https://david-dm.org/daniellmb/angular-uuid-service
[depstat-image]: https://david-dm.org/daniellmb/angular-uuid-service.png?theme=shields.io

[issues-url]: https://github.com/daniellmb/angular-uuid-service/issues
[issues-image]: http://img.shields.io/github/issues/daniellmb/angular-uuid-service.png

[bower-url]: http://bower.io/search/?q=angular-uuid-service
[bower-image]: https://badge.fury.io/bo/angular-uuid-service.png

[downloads-url]: https://www.npmjs.org/package/angular-uuid-service
[downloads-image]: http://img.shields.io/npm/dm/angular-uuid-service.png

[npm-url]: https://www.npmjs.org/package/angular-uuid-service
[npm-image]: https://badge.fury.io/js/angular-uuid-service.png

[irc-url]: http://webchat.freenode.net/?channels=angular-uuid-service
[irc-image]: http://img.shields.io/badge/irc-%23angular-uuid-service-brightgreen.png

[gitter-url]: https://gitter.im/daniellmb/angular-uuid-service
[gitter-image]: http://img.shields.io/badge/gitter-daniellmb/angular-uuid-service-brightgreen.png

[tip-url]: https://www.gittip.com/daniellmb
[tip-image]: http://img.shields.io/gittip/daniellmb.png
