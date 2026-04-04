# capradb

A database built from scratch in [Odin](https://odin-lang.org), for learning database internals.

Previously built in Go (see `go-archive` branch). Starting fresh in Odin to go deeper.

## Progress

- [x] Slotted pages — insert, get, update, delete, compaction
- [ ] Disk manager
- [ ] Buffer pool
- [ ] Heap file + table scan
- [ ] B+tree index
- [ ] Lock manager
- [ ] Two-phase locking
- [ ] MVCC
- [ ] Write-ahead log
- [ ] Recovery (ARIES)
- [ ] Catalog + statistics
- [ ] Query execution (volcano model)
- [ ] Join algorithms
- [ ] SQL parser + REPL

## Running tests

```bash
odin test page
odin test utils
```
