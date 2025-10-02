# zig-async: An Async Interface with a Runtime

This interface is a heavily modified version of [this implementation](https://github.com/ziglang/zig/tree/async-await-demo), based on [this Zulip discussion](https://zsf.zulipchat.com/#narrow/channel/454446-ecosystem/topic/uri.20singer's.20thoughts.20about.20async.20I.2FO).

* **Futures** are functions that may suspend.
The interface provides four primary methods for executing tasks asynchronously: `join`, `select`, `spawn`, and `cancel`.

* **`join`**: Waits for all given futures or poolers to complete.
* **`select`**: Waits for the first future or pooler to complete, and cancels all others.
* **`spawn`**: Launches a new task concurrently and returns a handle that can be converted into a pooler.
* **`cancel`**: Cancels a previously spawned task.

Currently, most functions for working with TCP sockets are implemented, along with file reading and writing functions.

At the moment, this runtime only works on linux, contributions from anyone who knows a bit about windows are welcome.
