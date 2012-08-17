Running Tests
=============

To run Flux tests, run

    bundle exec rspec spec

These specs rely on a local Redis installation. They will run against database
number 15 in your instance and clear all data in that database when they run.
