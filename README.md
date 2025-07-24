# zig-async: An Async Interface with a Runtime

This interface is a heavily modified version of [this implementation](https://github.com/ziglang/zig/tree/async-await-demo), based on [this Zulip discussion](https://zsf.zulipchat.com/#narrow/channel/454446-ecosystem/topic/uri.20singer's.20thoughts.20about.20async.20I.2FO).

The interface introduces two basic asynchronous primitives: **futures** and **poolers**.

* **Futures** are functions that may suspend.
* **Poolers** are functions that return a nullable result—somewhat like Rust’s `Poll` trait.

The interface provides four primary methods for executing tasks asynchronously: `join`, `select`, `spawn`, and `cancel`.

* **`join`**: Waits for all given futures or poolers to complete.
* **`select`**: Waits for the first future or pooler to complete, and cancels all others.
* **`spawn`**: Launches a new task concurrently and returns a handle that can be converted into a pooler.
* **`cancel`**: Cancels a previously spawned task.

Currently, most functions for working with TCP sockets are implemented, along with file reading and writing functions.

All asynchronous I/O functions return a **Pooler**, which can be used to poll for results or awaited.
