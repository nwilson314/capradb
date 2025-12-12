# CapraDB 🐐

**CapraDB** is a distributed SQL database built from scratch in Go.
It is designed to be an educational deep-dive into database internals, following the architectures of systems like PostgreSQL, CockroachDB, and Vitess.

Why "Capra"? *Capra* is Latin for goat—because it eats any data you throw at it and climbs the mountains of scalability.

## Architecture

CapraDB follows a standard layered architecture:

1.  **Disk Manager:** Manages raw file I/O, reading/writing 4KB pages.
2.  **Buffer Pool:** Caches hot pages in RAM using LRU eviction.
3.  **Storage Engine:** Implements **Slotted Pages** and **B+Trees** for efficient data organization.
4.  **Execution Engine:** (Planned) Volcano-style query execution.
5.  **Distributed Layer:** (Planned) Raft consensus for replication and sharding.

## Current Status: Storage Engine (Week 3)

We are currently building the fundamental storage layer.

-   **Page Layout:** 4KB Slotted Pages (Header -> Slots -> Free Space <- Data).
-   **Record Management:** Insert, Get, Update variable-length records.
-   **Upcoming:** Disk Manager (File I/O).

## Directory Structure

-   `storage/page`: The Slotted Page implementation.
-   `storage/disk`: (Coming soon) The Disk Manager.

## Goals

This project aligns with the curriculum of:
-   **CMU 15-445** (Database Systems)
-   **MIT 6.824** (Distributed Systems)

The goal is not just to build a toy, but to understand the trade-offs in modern database design (LSM vs B-Tree, WAL vs Shadow Paging, etc.).
