The Flux API
============

Flux's API has one route for receiving events and a few routes for querying
values and counts.

The actual events accepted and values queryable depend on the Flux schema.
In what follows, we'll assume the following sample schema:

    // User following another user
    "client.gravity.actions.follow": [{
      "targets": ["[followedId].followerIds"],
      "add": "followerId"
    }]

Events
======

To register an event with Flux, call `/event/:event_name?event_params`. For 
example, executing a HTTP GET against

    http://flux.art.sy/event/client.gravity.actions.follow.user?followerId=user4ff448&followedId=user50000d

will add "user4ff448" to the set user50000d:followerIds.

Querying
========

Query the members of a set by calling `/query/:set_name`. For example, to query the
followers of user50000d, execute a HTTP GET against

    http://flux.art.sy/query/user50000d:followerIds

You can add a `max_results` parameter to restrict the size of the result set. `max_results`
defaults to 50 if it's omitted. If there are more than `max_results` results, you'll get
an opaque cursor back in the `next` field of the results. To continue paging through
results, pass this cursor as the cursor parameter of the next call to same query. For
example,

    http://flux.art.sy/query/user50000d:followerIds?max_results=1

might return

    { results: ['user50000e'], next: '1234' }

You can then call

    http://flux.art.sy/query/user50000d:followerIds?max_results=10&cursor=1234

To get the following 10 results. When there are no more results, you won't get a next
field in the result.

Counts
======

Flux keeps track of three types of counts: the exact current size of the set, an 
estimate of the total number of distinct items that have ever been stored in the set, 
and a count of the total number of adds that have been executed against the set.

The current size of the set is available by calling `/count/`:

    http://flux.art.sy/count/user50000d:followerIds

An estimate of the number of distinct items that have ever been in the set is
available at `/distinct/`:

    http://flux.art.sy/distinct/user50000d:followerIds

A count of the total number of adds is available at `/gross/`:

    http://flux.art.sy/gross/user50000d:followerIds