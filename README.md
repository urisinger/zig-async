# zig-async, an async interface equipped with a runtime
The interface is a heavily modified version of [This implementation](https://github.com/ziglang/zig/tree/async-await-demo) based on [this zulip chat](https://zsf.zulipchat.com/#narrow/channel/454446-ecosystem/topic/uri.20singer's.20thoughts.20about.20async.20I.2FO).

The interface has two basic async primites: futures and poolers, futures are just functions that might suspend, and poolers are just functions that return a nullable result(some of like rusts Poll trait).

The interface includes 4 methods for running tasks asynchronsly: join, select, spawn, and cancel. 

join: Waits for all futures/poolers to finish.
###
select: Waits for one future to finish, cancels all other futures.
###
spawn: Spawns a new task concurrently, returns a handle that can be made into a pooler.
###
cancel: Cancels a spawned future.
###

Right now most functions for communicating with a tcp socket are implemented, along with functions for reading/writing files.
###
All asynchronous io functions return a pooler you can use to check for results/await them.
