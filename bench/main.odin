package main

// Buffer pool benchmark. Run from capradb/:
//
//     odin run bench -o:speed -out:bench.bin
//
// Each scenario builds a fresh database, warms up, then measures for a fixed
// window. Page bytes aren't latched yet (that's page guards), so each writer
// bumps its own counter inside the page and no two threads share a byte. At
// the end those counters are checked against disk: a run that lost a write
// reports FAIL, whatever its throughput was.
//
// Hit rate is sampled by peeking at the page table on every 16th op. An
// in-flight read counts as a hit, since that fetch doesn't schedule its own.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import "../bpm"
import "../disk"
import pg "../page"
import "../utils"

DB_PATH :: "/tmp/capradb_bench.db"
DB_PAGES :: 5000 // 20 MB
SMALL_POOL :: 500 // 10% of the database
HOT_PAGES :: 400 // fits in SMALL_POOL
HOT_PERCENT :: 90
WARMUP :: 1 * time.Second
MEASURE :: 3 * time.Second
SAMPLE_MASK :: 15
COUNTER_BASE :: 64 // past the page header, each writer owns 4 bytes from here

Scenario :: struct {
    name:          string,
    pool_size:     u32,
    get_threads:   int,
    scan_threads:  int,
    skewed:        bool,
    write_percent: u64,
}

SCENARIOS := []Scenario{
    {name = "A all hits",          pool_size = DB_PAGES,   get_threads = 1},
    {name = "B all hits",          pool_size = DB_PAGES,   get_threads = 8},
    {name = "C mostly misses",     pool_size = SMALL_POOL, get_threads = 1},
    {name = "D mostly misses",     pool_size = SMALL_POOL, get_threads = 8},
    {name = "E skewed, 25% write", pool_size = SMALL_POOL, get_threads = 8, skewed = true, write_percent = 25},
    {name = "F E plus scans",      pool_size = SMALL_POOL, get_threads = 6, scan_threads = 2, skewed = true, write_percent = 25},
}

Worker :: struct #align(64) {
    bp:       ^bpm.Buffer_Pool,
    stop:     ^bool,
    scenario: ^Scenario,
    index:    int,
    is_scan:  bool,
    rng:      u64,
    writes:   []u32, // writes[id] = times this worker bumped page id
    sink:     u64,   // keeps scan reads from being optimized away

    // Read by main while the worker runs.
    ops:      u64,
    sampled:  u64,
    hits:     u64,
    failures: u64,
}

Counts :: struct {
    ops, sampled, hits: u64,
}

_next :: proc(w: ^Worker) -> u64 {
    x := w.rng
    x ~= x << 13
    x ~= x >> 7
    x ~= x << 17
    w.rng = x
    return x
}

_pick_page :: proc(w: ^Worker) -> u32 {
    if w.scenario.skewed && _next(w) % 100 < HOT_PERCENT {
        return u32(_next(w) % HOT_PAGES) + 1
    }
    return u32(_next(w) % DB_PAGES) + 1
}

_is_resident :: proc(bp: ^bpm.Buffer_Pool, id: u32) -> bool {
    sync.mutex_lock(&bp.latch)
    defer sync.mutex_unlock(&bp.latch)
    _, ok := bp.page_table[id]
    return ok
}

_counter_offset :: proc(worker_index: int) -> u32 {
    return COUNTER_BASE + u32(worker_index) * 4
}

_run_worker :: proc(w: ^Worker) {
    n: u64
    sampled: u64
    hits: u64
    scan_id := u32(w.index * DB_PAGES / 8)

    for !sync.atomic_load_explicit(w.stop, .Relaxed) {
        id: u32
        if w.is_scan {
            id = scan_id + 1
            scan_id = (scan_id + 1) % DB_PAGES
        } else {
            id = _pick_page(w)
        }

        if n & SAMPLE_MASK == 0 {
            sampled += 1
            if _is_resident(w.bp, id) do hits += 1
            sync.atomic_store_explicit(&w.sampled, sampled, .Relaxed)
            sync.atomic_store_explicit(&w.hits, hits, .Relaxed)
        }

        p := bpm.fetch_page(w.bp, id)
        if p == nil || p.id != id {
            sync.atomic_add_explicit(&w.failures, 1, .Relaxed)
            if p != nil do bpm.unpin_page(w.bp, id, false)
            continue
        }

        dirty := false
        if !w.is_scan && _next(w) % 100 < w.scenario.write_percent {
            offset := _counter_offset(w.index)
            c, _ := utils.read_u32_le(p.data[:], offset)
            utils.write_u32_le(p.data[:], offset, c + 1)
            w.writes[id] += 1
            dirty = true
        } else {
            w.sink += u64(p.data[0])
        }
        bpm.unpin_page(w.bp, id, dirty)

        n += 1
        sync.atomic_store_explicit(&w.ops, n, .Relaxed)
    }
}

_snapshot :: proc(w: ^Worker) -> Counts {
    return Counts{
        ops     = sync.atomic_load_explicit(&w.ops, .Relaxed),
        sampled = sync.atomic_load_explicit(&w.sampled, .Relaxed),
        hits    = sync.atomic_load_explicit(&w.hits, .Relaxed),
    }
}

_percent :: proc(part, whole: u64) -> f64 {
    if whole == 0 do return 0
    return 100 * f64(part) / f64(whole)
}

_fresh_db :: proc() -> ^disk.Disk_Manager {
    os.remove(DB_PATH)
    dm := disk.new_disk_manager(DB_PATH)
    for _ in 0 ..< DB_PAGES {
        _ = disk.allocate_page(dm)
    }
    return dm
}

_verify :: proc(dm: ^disk.Disk_Manager, workers: []Worker) -> bool {
    for id in u32(1) ..= DB_PAGES {
        page, ok := disk.read_page(dm, id)
        if !ok do return false
        for &w in workers {
            if w.is_scan do continue
            c, _ := utils.read_u32_le(page.data[:], _counter_offset(w.index))
            if c != w.writes[id] do return false
        }
    }
    return true
}

_run_scenario :: proc(s: ^Scenario) {
    dm := _fresh_db()
    defer {
        disk.close_disk_manager(dm)
        os.remove(DB_PATH)
    }
    bp := bpm.new_buffer_pool(s.pool_size, dm)

    total := s.get_threads + s.scan_threads
    workers := make([]Worker, total)
    defer delete(workers)
    threads := make([]^thread.Thread, total)
    defer delete(threads)

    stop := false
    for i in 0 ..< total {
        workers[i] = Worker{
            bp       = bp,
            stop     = &stop,
            scenario = s,
            index    = i,
            is_scan  = i >= s.get_threads,
            rng      = 0x9E3779B97F4A7C15 * u64(i + 1),
            writes   = make([]u32, DB_PAGES + 1),
        }
    }
    defer for &w in workers do delete(w.writes)

    for i in 0 ..< total {
        threads[i] = thread.create_and_start_with_poly_data(&workers[i], _run_worker, context)
    }

    time.sleep(WARMUP)

    before := make([]Counts, total)
    defer delete(before)
    for i in 0 ..< total do before[i] = _snapshot(&workers[i])
    start := time.tick_now()

    time.sleep(MEASURE)

    after := make([]Counts, total)
    defer delete(after)
    for i in 0 ..< total do after[i] = _snapshot(&workers[i])
    elapsed := time.duration_seconds(time.tick_since(start))

    sync.atomic_store(&stop, true)
    for t in threads {
        thread.join(t)
        thread.destroy(t)
    }

    bpm.destroy_buffer_pool(bp) // flushes every dirty page
    data_ok := _verify(dm, workers)

    get, scan: Counts
    failures: u64
    for i in 0 ..< total {
        c := &get
        if workers[i].is_scan do c = &scan
        c.ops += after[i].ops - before[i].ops
        c.sampled += after[i].sampled - before[i].sampled
        c.hits += after[i].hits - before[i].hits
        failures += workers[i].failures
    }

    fmt.printf("%-20s %7s %9s %12s %12s %8s %8s  %s",
        s.name, fmt.tprint(s.pool_size), fmt.tprintf("%d+%d", s.get_threads, s.scan_threads),
        fmt.tprint(u64(f64(get.ops) / elapsed)), fmt.tprint(u64(f64(scan.ops) / elapsed)),
        fmt.tprintf("%.1f%%", _percent(get.hits, get.sampled)),
        fmt.tprintf("%.1f%%", _percent(scan.hits, scan.sampled)),
        data_ok && failures == 0 ? "ok" : "FAIL")
    if failures > 0 do fmt.printf(" (%d failed fetches)", failures)
    fmt.println()
}

main :: proc() {
    fmt.printf("%d pages (%d MB), %v warmup, %v measured\n\n",
        DB_PAGES, DB_PAGES * pg.PAGE_SIZE / (1024 * 1024), WARMUP, MEASURE)
    fmt.printf("%-20s %7s %9s %12s %12s %8s %8s  %s\n",
        "scenario", "frames", "get+scan", "get ops/s", "scan ops/s", "get hit", "scan hit", "data")
    for &s in SCENARIOS {
        _run_scenario(&s)
    }
}
