/**
 * @file
 *
 * ### Responsibilities
 * - unit test angular-uuid-service.js
 *
 * @author Daniel Lamb <dlamb.open.source@gmail.com>
 */
'use strict';

describe('Service: uuid', function () {
  var rfc4122;

  // Use to inject the code under test
  function _inject() {
    inject(function (_rfc4122_) {
      rfc4122 = _rfc4122_;
    });
  }

  // Call this before each test, except where you are testing for errors
  function _setup() {
    // Inject the code under test
    _inject();
  }

  beforeEach(function () {
    // Load the service's module
    module('uuid');
  });

  describe('the service api', function () {
    beforeEach(function () {
      // Inject with expected values
      _setup();
    });

    it('should exist', function () {
      expect(!!rfc4122).toBe(true);
    });

    it('should provide a method called v4', function () {
      expect(typeof rfc4122.v4).toBe('function');
    });

  });

  describe('v4', function () {
    var iterations = 10000,
        /*
        The version 4 uuid format is xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
        where 'x' is any hexadecimal digit and 'y' is either 8, 9, a, or b.
        */
        valid = /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/;

    function verify(method, iterations, callback) {
      var start = new Date(), i;
      // call the service method N times
      for(i = 0; i < iterations; i++) {
        // send the uuid to the callback for analysis
        callback(method());
      }
      // return total execution time
      return (new Date().getTime() - start.getTime());
    }

    it('should produce valid rfc4122 v4 uuids', function () {
      verify(rfc4122.v4, iterations, function(uuid) {
        expect(uuid).toMatch(valid);
      });
    });

    it('should not have uuid collisions', function () {
      var list = {};
      verify(rfc4122.v4, iterations, function(uuid) {
        expect(list[uuid]).toBeUndefined();
        list[uuid] = uuid;
      });
    });

    it('should be fast', function () {
      var time = verify(rfc4122.v4, iterations, function(){});
      console.log('average uuid generation time ' + time/iterations);
      expect(time).toBeLessThan(500);
    });

  });

});
