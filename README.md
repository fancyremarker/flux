[![Build Status](https://secure.travis-ci.org/artsy/flux.png)](http://travis-ci.org/artsy/flux)
[![Dependency Status](https://gemnasium.com/artsy/flux.png)](https://gemnasium.com/artsy/flux)

Flux
====

Flux is a database that:

* Accepts input in the form of structured events.
* Computes data joins at write time via static event transformations.
* Exposes a flat keyspace for querying ordered sets of values and counts of values.

Some motivating examples:

* Rolled-up counts for analytics: an event like a pageview needs to be translated into a series of counter increments,
so viewing Andy Warhol's artist page might trigger an increment of the counters "artist:pageviews:andy-warhol:2012-08-08:US-NY",
"artist:pageviews:andy-warhol:2012-08:US-NY", "artist:pageviews:andy-warhol:2012:US-NY", "artist:pageviews", etc.
Each of these counters can be queried invididually.

* Pre-computing a join that's too expensive to run at query time: a user's feed can be represented as a join between the
list of users they follow and the list of posts by each of those users, sorted by the time of the post. Instead of running
the join at query time in Flux, the 'post' event is instead translated into multiple writes onto the feeds of all followers
of the posting user, which makes querying a feed a very fast operation.

More information
----------------

* [Getting Started](doc/GettingStarted.md)
* [Running Tests](doc/RunningTests.md)
* [McQuery Language](doc/MQL.md)
* [API] (doc/API.md)

Contributing
------------

Fork the project. Make your feature addition or bug fix with tests. Send a pull request.

Copyright and License
---------------------

MIT License, see [LICENSE](LICENSE.md) for details.

Copyright (c) 2013 [Artsy, Inc.](http://artsy.github.com), [Aaron Windsor](https://github.com/aaw), [Frank Macreery](https://github.com/macreery) and Contributors.
