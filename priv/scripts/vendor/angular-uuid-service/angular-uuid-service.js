/**
 * @file angular-uuid-service is a tiny standalone AngularJS UUID/GUID generator service that is RFC4122 version 4 compliant.
 * @author Daniel Lamb <dlamb.open.source@gmail.com>
 */
angular.module('uuid', []).factory('rfc4122', function () {
  function getRandom(max) {
    return Math.random() * max;
  }

  return {
    v4: function () {
      var id = '', i;

      for(i = 0; i < 36; i++)
      {
        if (i === 14) {
          id += '4';
        }
        else if (i === 19) {
          id += '89ab'.charAt(getRandom(4));
        }
        else if(i === 8 || i === 13 || i === 18 || i === 23) {
          id += '-';
        }
        else
        {
          id += '0123456789abcdef'.charAt(getRandom(16));
        }
      }
      return id;
    }
  };
});
