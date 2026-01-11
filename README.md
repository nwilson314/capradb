# CapraDB

**CapraDB** is a distributed SQL database built from scratch in Go.
It is designed to be an educational deep-dive into database internals, following the architectures of systems like PostgreSQL, CockroachDB, and Vitess.

Why "Capra"? *Capra* is Latin for goat—because it eats any data you throw at it and climbs the mountains of scalability.

## Architecture

CapraDB follows a standard layered architecture:

1.  **Disk Manager:** Manages raw file I/O, reading/writing 4KB pages.
2.  **Buffer Pool:** Caches hot pages in RAM using ARC eviction policy.
3.  **Storage Engine:** Implements **Slotted Pages** and **B+Trees** for efficient data organization.
4.  **Execution Engine:** (Planned) Volcano-style query execution.
5.  **Distributed Layer:** (Planned) Raft consensus for replication and sharding.

## Current Status: Week 6 Complete

### Completed

- **Slotted Pages** (`storage/page`)
  - 4KB pages with Header -> Slots -> Free Space <- Data layout
  - Insert, Get, Update variable-length records

- **Disk Manager** (`storage/disk`)
  - File I/O for reading/writing pages
  - Page allocation

- **ARC Replacer** (`storage/replacer`)
  - Adaptive Replacement Cache eviction policy
  - O(1) RecordAccess, SetEvictable, Evict operations
  - Ghost lists (B1/B2) for adaptive learning
  - Passes CMU 15-445 test suite

- **Disk Scheduler** (`storage/disk`)
  - Background worker goroutine with request queue
  - Async read/write via channels
  - Batch request support

- **Buffer Pool Manager** (`storage/buffer`)
  - Fixed-size frame pool with page caching
  - Page table for O(1) lookups
  - Free list + ARC eviction for frame allocation
  - Pin counting to prevent eviction of in-use pages
  - Dirty page tracking and flush on eviction
  - Thread-safe with mutex locking

### Up Next

- B+Tree index structure (Week 7-10)

## Directory Structure

```
storage/
├── page/       # Slotted page implementation
├── disk/       # Disk manager and scheduler
├── replacer/   # ARC cache replacement policy
└── buffer/     # Buffer pool manager
```

## Testing

Run all tests:
```bash
go test ./...
```

Run tests for a specific package:
```bash
go test ./storage/replacer/... -v
```

Run the ARC performance test (CMU 15-445 threshold: 262k ops < 3s):
```bash
go test ./storage/replacer/... -v -run Performance
```

Run benchmarks:
```bash
go test ./storage/replacer/... -bench=. -benchmem
```

## Goals

This project aligns with the curriculum of:
-   **CMU 15-445** (Database Systems)
-   **MIT 6.824** (Distributed Systems)

The goal is not just to build a toy, but to understand the trade-offs in modern database design (LSM vs B-Tree, WAL vs Shadow Paging, etc.).
