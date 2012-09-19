MaQuery Language
================

MaQuery Language (MQL) describes the translation of an event into a series of 
writes to a flat key space in real time. An _event_ is a namespace plus an 
attribute hash, for example "client:gravity:action:post" along with the hash 
`{ 'userId': 'user:1', 'postId': 'post:3' }`. An MQL schema is a JSON hash that 
maps event prefixes to sequences of handlers. An event triggers all handlers 
that are attached to prefixes of its namespace.

Intro to MQL
============

Here's a sample MQL schema:

    {
      "client:gravity:action": [{ 
        "targets": ["['unique']", "[@eventName]", "[@day, @week, @month]"], 
        "add": "@requestIP" 
      }],
      "client:gravity:action:follow": [{ 
        "targets": ["[followedId].followerIds"], 
        "add": "followerId" 
      }]
    }

Given the event with namespace "client:gravity:action:follow" and attributes 
`{'followedId': 'user:a', 'followerId': 'user:b'}`, both of the handlers in the 
schema above are triggered, since both "client:gravity:action:follow" and 
"client:gravity:action" are prefixes of the event namespace. When triggered, 
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

and adds the request IP to the set associated with each of those labels.

The dot notation allows you to join values together to form a list of keys. An 
expression of the form X.Y means "for each string L in X, replace L by all 
strings in the set associated with the label L:Y. Note that for an expression X.Y
to be valid, X must be a list, so a chain of ids joined by dots has to start off 
with a literal list of ids. For example, 

    targets: ["['a','b'].artworks"]
    add: "'artwork:123'"

Adds the string 'artwork:123' to the sets a:artworks and b:artworks. If 
we also stored artist ids in sets of the form 'artwork:123:artists', we 
could apply dot notation again to write artist ids:

    targets: ["['a','b'].artworks.artists"]
    add: "'artist:345'"

Logically, the "add" command adds the value to a set whose values are sorted
by the time they're added to the set. There's also a "remove" command that
removes items from the set.

You can bound the size of sets using the maxStoredValues field:

    targets: ["['a','b'].artworks.artists"]
    add: "'artist:345'"
    maxStoredValues: 10

This will bound the size of the set at 10 items, removing values in a least
recently added fashion. If you don't specify maxStoredValues, the size of
the set is unbounded. A maxStoredValues value of 1 can be used to simulate
a simple variable, since any addition to the set will evict the previous
singleton member. A maxStoredValues value of 0 can be used if you're only
interested in storing counts for an event, but never want to actually query
the members of the set.

