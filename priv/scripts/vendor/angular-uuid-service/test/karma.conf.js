/**
 * @file
 *
 * ### Responsibilities
 * - configure karma for jasmine testing
 *
 * Scaffolded with generator-microjs v0.1.2
 *
 * @author Daniel Lamb <dlamb.open.source@gmail.com>
 */
'use strict';

module.exports = function (config) {
  config.set({
    /*
     Path used to resolve file paths
     */
    basePath : '../',

    /*
     Test results reporter to use:
     dots, progress, nyan, story, coverage etc.
     */
    reporters: ['dots', 'coverage'],

    /*
     Test pre-processors
     */
    preprocessors: {
      'angular-uuid-service.js': ['coverage']
    },

    /*
     Test coverage reporters:
     html, lcovonly, lcov, cobertura, text-summary, text, teamcity, clover etc.
     */
    coverageReporter: {
      reporters: [{
        type: 'text',
        dir: 'test/coverage'
      }, {
        type: 'lcov',
        dir: 'test/coverage'
      }]
    },

    /*
     Locally installed browsers
     Chrome, ChromeCanary, PhantomJS, Firefox, Opera, IE, Safari, iOS etc.
     */
    browsers: ['PhantomJS'],

    /*
     Enable / disable watching file and executing tests whenever any file changes
     */
    autoWatch: false,

    /*
     Continuous Integration mode: if true, it capture browsers, run tests and exit
     */
    singleRun: true,

    /*
     Report slow running tests, time in ms
     */
    reportSlowerThan: 2000,

    /*
     If browser does not capture in given timeout [ms], kill it
     Increasing timeout in case connection in Travis CI is slow
     */
    captureTimeout: 100000,

    /*
     Logging Level:
     DISABLE, ERROR, WARN, INFO, DEBUG
    */
    logLevel: 'WARN',

    /*
     Test framework to use:
     jasmine, mocha, qunit etc.
     */
    frameworks: ['jasmine']
  });
};
