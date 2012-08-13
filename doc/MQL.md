MaQuery Language
================

MaQuery Language (MQL) describes the translation of an event into a series of 
writes to a flat key space in real time. An _event_ is a namespace plus an 
attribute hash, for example "client.gravity.actions.post" along with the hash 
`{ 'userId': 'user:1', 'postId': 'post:3' }`. An MQL schema is a JSON hash that 
maps event prefixes to sequences of handlers. An event triggers all handlers 
that are attached to prefixes of its namespace.

Intro to MQL
============

Here's a sample MQL schema:

    {
      "client.gravity.actions": [{ 
        "targets": ["['unique']", "[@eventName]", "[@day, @week, @month]"], 
        "add": "@requestIP" 
      }],
      "client.gravity.actions.follow": [{ 
        "targets": ["[followedId].followerIds"], 
        "add": "followerId" 
      }]
    }

Given the event with namespace "client.gravity.actions.follow" and attributes 
`{'followedId': 'user:a', 'followerId': 'user:b'}`, both of the handlers in the 
schema above are triggered, since both "client.gravity.actions.follow" and 
"client.gravity.actions" are prefixes of the event namespace. When triggered, 
each handler expands its targets list into a list of key names, each of which 
represent sets of values, and adds the value of the `add` parameters to 
each of those sets.

Identifiers in MQL are either:
* Single-quoted literals like `'unique'` above, which evaluate to themselves
* Keys from the triggering event's attributes, which evaluate to their 
  respective values
* Built-in variables like `@eventName`, `@requestIP`, or `@day` above, which 
  evaluate to strings on the server - `@eventName` evaluates to the namespace 
  of the triggering event, `@requestIP` returns the IP associated with the 
  event and `@day` evaluates to a label describing the current day on the 
  server.

Identifiers can be grouped into expressions by either putting them into a list
(like `[@day, @week, @month]` above) or joined together with the dot notation 
(like `[followedId].followerIds` above.) The targets field takes a list of 
expressions and computes the cartesian product of those expressions, 
flattening out the resulting sets into keys by joining them with colons. For 
example,

    targets: ["['a']", "['b','c']", "['d','e','f']"]
    add: "@requestIP"

expands targets into the list of labels:

    [a:b:d, a:b:e, a:b:f, a:c:d, a:c:e, a:c:f]

and adds a hash computed from the attributes to the set associated with each 
of those labels.

The dot notation allows you to join values together to form a list of keys. An 
expression of the form X.Y means "for each string L in X, replace L by all 
strings in the set associated with the label L:Y. For example, 

    targets: ["['a','b'].artwork_ids"]
    add: "'artwork:123'"

Adds the string 'artwork:123' to the sets a:artwork_ids and b:artwork_ids. If 
we also stored artist ids in sets of the form 'artwork:123:artist_ids', we 
could apply dot notation again to write artist ids:

    targets: ["['a','b'].artworks_ids.artist_ids"]
    add: "'artist:345'"

Logically, the "add" command adds the value to a set whose values are sorted
by the time they're added to the set. There's also a "remove" command that
removes items from the set and a "replaceWith" command that clears the underlying
set and adds the associated value.

Querying MQL
============

Any set or list can be queried by specifying its name:

    artwork:123:artist_ids

You can query the size of a set or list by prefixing the query with #:

    #artwork:123:artist_ids

A Sample MQL Schema
===================

Here's a more involved schema with some more advanced definitions:

    {
      // User posting, need to write the post to all of the user's followers' feeds
      // Example: _flx.event("client.gravity.actions.post", { id: 'user:4ff334', postId: 'post:500033' })
      // Assuming that the set user:4ff3344:followerIds contains user:50000dd and user:50000ff, this
      // event triggers the write 'post:500033' to the sets user:50000dd:feedIds and user:50000ff:feedIds
      "client.gravity.actions.post": [{
        "targets": ["[id].followerIds.feedIds"],
        "add": "postId"
      }],

      // User following another user
      // Example: _flx.event("client.gravity.actions.follow.user", { followerId: 'user:4ff448', followedId: 'user:50000d' })
      // triggers the write 'user:4ff448' to the sets defined by strings contained in the set 'user:50000d:followerIds'
      "client.gravity.actions.follow": [{
        "targets": ["[followedId].followerIds"],
        "add": "followerId"
      }],

      // User unfollowing another user
      // Example: _flx.event("client.gravity.actions.unfollow.user", { followerId: 'user:4ff448', followedId: 'user:50000d' })
      // triggers the write 'user:4ff448' to the sets defined by strings contained in the set 'user:50000d:followerIds'
      "client.gravity.actions.unfollow": [{
        "targets": ["[followedId].followerIds"],
        "remove": "followerId"
      }],

      // Counting user actions:
      // Example: _flx.event("client.gravity.actions.logout", { id: 'user:4ff334' }
      // triggers the write of a hash computed from { id: 'user:4ff334' } to the sets
      // unique:client.gravity.actions.logout:2012-08-08, unique:client.gravity.actions.logout:2012-08, 
      // and unique:client.gravity.actions.logout:2012. It also triggers the write '1' to the lists
      // gross:client.gravity.actions.logout:2012-08-08:NY, gross:client.gravity.actions.logout:2012-08-08:NY-NY, etc.
      "client.gravity.actions": [{
        "targets": ["['unique']", "[@eventName]", "[@day, @week, @month]"],
        "add": "@requestIP"
      },
      {
        "targets": ["['gross']", "[@eventName]", "[@day, @week, @month]", "[@state, @city]"],
        "add": "@uniqueId"
      }],

      // Identify an admin with a user:
      // _flx.event("domain.identify.user", { userId: 'user:abc', 'adminId': 'admin:xyz' })
      // triggers the write 'admin:xyz' to the set 'user:abc:adminId', after clearing that set
      "domain.identify.user": [{
        "targets": ["[userId].adminId"],
        "replaceWith": "adminId"
      }]
    }