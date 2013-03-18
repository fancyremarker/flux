McQuery Language
================

McQuery Language (MQL) describes the translation of an event into a series of
writes to a flat key space in real time. An _event_ is a namespace plus an
attribute hash, for example "client:gravity:action:post" along with the hash
`{ 'user': 'user:1', 'post': 'post:3' }`. An MQL schema is a JSON hash that
maps event prefixes to sequences of handlers. An event triggers all handlers
that are attached to prefixes of its namespace.

Intro to MQL
============

Here's a sample MQL schema:

    {
      "client:gravity:action": [{
        "targets": ["['unique']", "[@event_name]", "[@daily, @weekly, @monthly]"],
        "add": "@request_ip"
      }],
      "client:gravity:action:follow": [{
        "targets": ["[followee].followers"],
        "add": "follower"
      },
      {
        "targets": ["[followers]", "[@weekly]"],
        "count_frequency": "followee",
        "max_stored_values": 10
      }],
   }

Given the event with namespace "client:gravity:action:follow" and attributes
`{'followee': 'user:a', 'follower': 'user:b'}`, both of the handlers in the
schema above are triggered, since both "client:gravity:action:follow" and
"client:gravity:action" are prefixes of the event namespace. When triggered,
each handler expands its targets list into a list of key names, each of which
represent sets of values, and performs an action on the expanded key names
using the value specified by "add" or "count_frequency". In the two "add"
handlers, the specified value is added to a set of the most recent values
seen, while the "count_frequency" operation keeps track of the top 10 values
seen.

Identifiers in MQL are either:
* Single-quoted literals like `'unique'` above, which evaluate to themselves
* Keys from the triggering event's attributes, which evaluate to their
  respective values
* Built-in variables like `@event_name`, `@request_ip`, or `@day` above, which
  evaluate to strings on the server - `@event_name` evaluates to the namespace
  of the triggering event, `@request_ip` returns the IP associated with the
  event and `@day` evaluates to a label describing the current day on the
  server.

If the identifier in an event handler can't be resolved from the rules above
for a particular event (for example, a key from the event attributes that doesn't
exist), the entire event is ignored. This makes optimistic schemas possible that
implement conditional logic via silent failures, like:

    {
      "client:gravity:action": [{
        "targets": ["['users']"],
        "add": "user_id"
      }],
      "client:gravity:action:": [{
        "targets": ["['visitors']"
        "add": "visitor_id"
      }
    }

The above schema will distribute any events with only user_id defined to the users
key, any events with only the visitor_id key defined to the visitors key, and
anything with both user_id and visitor_id definied to both keys.

Identifiers can be grouped into expressions by either putting them into a list
(like `[@day, @week, @month]` above) or joined together with the dot notation
(like `[followee].followers` above.) The targets field takes a list of
expressions and computes the cartesian product of those expressions,
flattening out the resulting sets into keys by joining them with colons. For
example,

    targets: ["['a']", "['b','c']", "['d','e','f']"]
    add: "@request_ip"

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

Logically, the "add" operation adds the value to a set whose values are sorted
by the time they're added to the set. There's also a "remove" operation that
removes items from the set and a "count_frequency" operation that stores a
leaderboard of the top K items, by gross frequency, that have triggered the
event.

A "count_frequency" handler might look like this:

    targets: ["[artwork_id].partner_id"]
    count_frequency: "artwork_id"

and will store the top K (100 by default) artworks viewed, bucketed by partner.

You can bound the size of sets and leaderboards using the max_stored_values field:

    targets: ["['a','b'].artworks.artists"]
    add: "'artist:345'"
    max_stored_values: 10

This will bound the size of the set at 10 items, removing values in a least
recently added fashion. If you don't specify max_stored_values, the size of
the set is unbounded. A max_stored_values value of 1 can be used to simulate
a simple variable, since any addition to the set will evict the previous
singleton member. A max_stored_values value of 0 can be used if you're only
interested in storing counts for an event, but never want to actually query
the members of the set.

You can disable either gross or distinct counters by setting the store_gross_counters
and store_distinct_counters fields, respectively, to false (both default to true
if not specified):

    targets: ["['a','b'].artworks.artists"]
    add: "'artist:345'"
    store_gross_counters: false,
    store_distinct_counters: false
