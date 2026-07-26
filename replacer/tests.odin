package replacer

import "core:testing"

/*
    ARC replacer test suite — ordered as a ladder. Each test builds on the
    behavior pinned by the ones before it. Implement in order; don't skip.

    Interface this suite defines (stub these first so the package compiles):

        new_arc       :: proc(c: u32) -> ^Arc
        destroy_arc   :: proc(arc: ^Arc)                     // frees ALL nodes, maps, arc itself
        arc_size      :: proc(arc: ^Arc) -> u32              // count of evictable frames
        record_access :: proc(arc: ^Arc, frame_id: u32, page_id: u32)
        set_evictable :: proc(arc: ^Arc, frame_id: u32, evictable: bool)
        evict         :: proc(arc: ^Arc) -> (frame_id: u32, ok: bool)
        remove        :: proc(arc: ^Arc, frame_id: u32)      // hard purge, NO ghost

    Spec decisions these tests encode:
      - A frame is NON-evictable when first recorded (BPM just pinned it).
      - evict() victims always leave a ghost (page_id into B1 or B2).
      - remove() leaves no ghost — the page is gone, not "regrettable".
      - Eviction rule: |T1| >= p -> victim from T1's LRU end, else from T2;
        skip non-evictable entries; fall through to the other list if the
        chosen one has no candidate; (0, false) only if neither does.
      - B1 hit: p = min(c, p + max(1, |B2|/|B1|)). B2 hit: p = max(0, p - max(1, |B1|/|B2|)).
      - set_evictable / remove on an unknown frame: silent no-op.

    Tests live in the same package, so a few of them assert arc.p directly —
    white-box on purpose, since adaptation is otherwise hard to observe.
*/

// ---------------------------------------------------------------------------
// The ladder
// ---------------------------------------------------------------------------

// 01: construction and the empty state. An empty replacer has size 0 and
// nothing to evict.
@(test)
test_01_new_arc_empty :: proc(t: ^testing.T) {
    arc := new_arc(10)
    defer destroy_arc(arc)

    testing.expect_value(t, arc.c, u32(10))
    testing.expect_value(t, arc_size(arc), u32(0))

    _, ok := evict(arc)
    testing.expect(t, !ok, "evict on empty replacer must return ok=false")
}

// 02: record_access introduces frames, but new frames are NOT evictable —
// the BPM records an access at fetch time, when the pin count is 1.
@(test)
test_02_new_frames_start_pinned :: proc(t: ^testing.T) {
    arc := new_arc(10)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 2, 102)
    testing.expect_value(t, arc_size(arc), u32(0))

    _, ok := evict(arc)
    testing.expect(t, !ok, "nothing evictable yet")
}

// 03: set_evictable drives size up and down; setting the same value twice
// must not double-count.
@(test)
test_03_set_evictable_size :: proc(t: ^testing.T) {
    arc := new_arc(10)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 2, 102)

    set_evictable(arc, 1, true)
    testing.expect_value(t, arc_size(arc), u32(1))
    set_evictable(arc, 2, true)
    testing.expect_value(t, arc_size(arc), u32(2))
    set_evictable(arc, 2, true) // idempotent
    testing.expect_value(t, arc_size(arc), u32(2))
    set_evictable(arc, 1, false)
    testing.expect_value(t, arc_size(arc), u32(1))
}

// ——— LADDER GATE ——————————————————————————————————————————————————————
// Everything below is commented out. To activate the next test, move the
// `/*` on the next line DOWN past it. The closing `*/` is at end of file.

// 04: a single evictable frame gets evicted; afterwards the replacer has
// fully forgotten it as a *frame* (size 0, second evict fails).
@(test)
test_04_evict_single :: proc(t: ^testing.T) {
    arc := new_arc(10)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    set_evictable(arc, 1, true)

    victim, ok := evict(arc)
    testing.expect(t, ok, "evict should succeed")
    testing.expect_value(t, victim, u32(1))
    testing.expect_value(t, arc_size(arc), u32(0))

    _, ok2 := evict(arc)
    testing.expect(t, !ok2, "frame must be gone after eviction")
}


// 05: once-accessed frames live in T1 and are evicted in LRU order
// (first-recorded goes first). p is 0, so T1 is always the victim list.
@(test)
test_05_t1_lru_order :: proc(t: ^testing.T) {
    arc := new_arc(10)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 2, 102)
    record_access(arc, 3, 103)
    set_evictable(arc, 1, true)
    set_evictable(arc, 2, true)
    set_evictable(arc, 3, true)

    v1, _ := evict(arc)
    v2, _ := evict(arc)
    v3, _ := evict(arc)
    testing.expect_value(t, v1, u32(1))
    testing.expect_value(t, v2, u32(2))
    testing.expect_value(t, v3, u32(3))
}

// 06: a second access promotes a frame from T1 to T2. With p=0, T1 empties
// out before any T2 frame is touched — so the twice-accessed frame is
// evicted LAST even though it was recorded FIRST.
@(test)
test_06_promotion_to_t2 :: proc(t: ^testing.T) {
    arc := new_arc(10)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 2, 102)
    record_access(arc, 3, 103)
    record_access(arc, 1, 101) // second touch -> T2
    set_evictable(arc, 1, true)
    set_evictable(arc, 2, true)
    set_evictable(arc, 3, true)

    v1, _ := evict(arc)
    v2, _ := evict(arc)
    v3, _ := evict(arc)
    testing.expect_value(t, v1, u32(2))
    testing.expect_value(t, v2, u32(3))
    testing.expect_value(t, v3, u32(1))
}

// 07: pinned frames are invisible to evict(), even when they are the LRU
// candidate. When ALL frames are pinned, evict() must fail — this is the
// "buffer pool full of pinned pages" case the BPM will surface as an error.
@(test)
test_07_evict_skips_pinned :: proc(t: ^testing.T) {
    arc := new_arc(10)
    defer destroy_arc(arc)

    record_access(arc, 1, 101) // stays pinned (default)
    record_access(arc, 2, 102)
    record_access(arc, 3, 103)
    set_evictable(arc, 2, true)
    set_evictable(arc, 3, true)

    v1, ok1 := evict(arc)
    testing.expect(t, ok1)
    testing.expect_value(t, v1, u32(2)) // 1 is LRU but pinned -> skipped

    v2, ok2 := evict(arc)
    testing.expect(t, ok2)
    testing.expect_value(t, v2, u32(3))

    _, ok3 := evict(arc)
    testing.expect(t, !ok3, "only pinned frames remain: evict must fail")

    set_evictable(arc, 1, true)
    v4, ok4 := evict(arc)
    testing.expect(t, ok4, "unpinning makes it eligible again")
    testing.expect_value(t, v4, u32(1))
}

// 08: remove() is a hard purge — no ghost. If the page comes back later it
// is treated as brand new (T1, no p adjustment). Contrast with eviction,
// which leaves a B1 ghost that WOULD bump p and resurrect into T2.
@(test)
test_08_remove_leaves_no_ghost :: proc(t: ^testing.T) {
    arc := new_arc(2)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 1, 101) // promote 101 -> T2
    set_evictable(arc, 1, true)
    record_access(arc, 2, 102) // -> T1
    set_evictable(arc, 2, true)

    remove(arc, 2)
    testing.expect_value(t, arc_size(arc), u32(1))

    record_access(arc, 2, 102) // same page returns: must be a cold miss
    set_evictable(arc, 2, true)
    testing.expect_value(t, arc.p, u32(0)) // no ghost hit happened

    // 102 must be back in T1 (evicted before the T2 resident)
    v1, _ := evict(arc)
    testing.expect_value(t, v1, u32(2))
}

// 09: eviction from T1 leaves a B1 ghost. Re-accessing that page is a ghost
// hit: p grows, and the page resurrects into T2 — so it now outlives
// once-touched pages that were recorded after it.
@(test)
test_09_b1_ghost_resurrection :: proc(t: ^testing.T) {
    arc := new_arc(3)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 2, 102)
    record_access(arc, 3, 103)
    set_evictable(arc, 1, true)
    set_evictable(arc, 2, true)
    set_evictable(arc, 3, true)

    v, _ := evict(arc) // T1 LRU = frame 1, page 101 -> B1
    testing.expect_value(t, v, u32(1))

    // BPM reloads page 101 into the freed frame: B1 hit.
    record_access(arc, 1, 101)
    set_evictable(arc, 1, true)
    testing.expect_value(t, arc.p, u32(1)) // p = min(3, 0 + max(1, 0/1)) = 1

    // 101 is in T2 now: both remaining T1 frames go first.
    v1, _ := evict(arc)
    v2, _ := evict(arc)
    v3, _ := evict(arc)
    testing.expect_value(t, v1, u32(2))
    testing.expect_value(t, v2, u32(3))
    testing.expect_value(t, v3, u32(1))
}

// 10: the frequency side. Once p > |T1|, victims come from T2 and leave B2
// ghosts; a B2 hit shrinks p back. Walks p up to 1 and back down to 0.
@(test)
test_10_b2_ghost_shrinks_p :: proc(t: ^testing.T) {
    arc := new_arc(2)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 1, 101) // 101 -> T2
    set_evictable(arc, 1, true)
    record_access(arc, 2, 102) // 102 -> T1
    set_evictable(arc, 2, true)

    v1, _ := evict(arc) // |T1|=1 >= p=0 -> frame 2, page 102 -> B1
    testing.expect_value(t, v1, u32(2))

    record_access(arc, 2, 102) // B1 hit: p -> 1, 102 -> T2
    set_evictable(arc, 2, true)
    testing.expect_value(t, arc.p, u32(1))

    v2, _ := evict(arc) // |T1|=0 < p=1 -> T2 LRU = frame 1, page 101 -> B2
    testing.expect_value(t, v2, u32(1))

    record_access(arc, 1, 101) // B2 hit: p = max(0, 1 - max(1, 0/1)) = 0
    set_evictable(arc, 1, true)
    testing.expect_value(t, arc.p, u32(0))
}

// 11: THE test — scan resistance, the reason ARC exists. Two hot pages are
// promoted to T2, then a stream of never-repeated pages churns through the
// pool. The hot frames must never be chosen while any scan frame is
// available, and must be the last two standing.
@(test)
test_11_scan_resistance :: proc(t: ^testing.T) {
    arc := new_arc(4)
    defer destroy_arc(arc)

    // hot set: pages 201 (frame 1) and 202 (frame 2), accessed twice each
    record_access(arc, 1, 201)
    record_access(arc, 1, 201)
    set_evictable(arc, 1, true)
    record_access(arc, 2, 202)
    record_access(arc, 2, 202)
    set_evictable(arc, 2, true)

    // fill the remaining frames with the start of the scan
    record_access(arc, 3, 301)
    set_evictable(arc, 3, true)
    record_access(arc, 4, 302)
    set_evictable(arc, 4, true)

    // scan continues: each new page needs a frame -> evict, reload, unpin
    for page in u32(303) ..= u32(308) {
        victim, ok := evict(arc)
        testing.expect(t, ok, "scan must always find a victim")
        testing.expect(t, victim != 1 && victim != 2,
            "hot T2 frame evicted by a scan — not scan resistant")
        record_access(arc, victim, page)
        set_evictable(arc, victim, true)
    }

    // drain: the two survivors of the scan go first, hot frames last
    d1, _ := evict(arc)
    d2, _ := evict(arc)
    testing.expect(t, d1 != 1 && d1 != 2, "scan leftovers drain first")
    testing.expect(t, d2 != 1 && d2 != 2, "scan leftovers drain first")
    d3, _ := evict(arc) // T2 LRU: 201 promoted before 202
    d4, _ := evict(arc)
    testing.expect_value(t, d3, u32(1))
    testing.expect_value(t, d4, u32(2))
}

// ---------------------------------------------------------------------------
// Corner cases — these target implementation mistakes, not the algorithm
// ---------------------------------------------------------------------------

// C1: page identity vs frame identity. A page evicted from one frame can
// come back in a DIFFERENT frame; the ghost hit must still fire, and evict
// must return the NEW frame id. Catches any impl that keyed ghosts by frame.
@(test)
test_c1_page_returns_in_different_frame :: proc(t: ^testing.T) {
    // NOTE: originally written with c=2, where the ghost bound |T1|+|B1| <= c
    // legitimately trims page 101's ghost before it returns — the original
    // expected p==1 was an authoring error (the implementation was right).
    // c=3 gives the regret a window to survive.
    arc := new_arc(3)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    set_evictable(arc, 1, true)
    record_access(arc, 2, 102)
    set_evictable(arc, 2, true)

    v1, _ := evict(arc) // frame 1, page 101 -> B1
    testing.expect_value(t, v1, u32(1))

    record_access(arc, 1, 103) // frame 1 reused for an unrelated page
    set_evictable(arc, 1, true)

    record_access(arc, 3, 101) // page 101 returns — in frame 3 now
    set_evictable(arc, 3, true)
    testing.expect_value(t, arc.p, u32(1)) // ghost hit fired despite the new frame

    v2, _ := evict(arc) // |T1|=2 >= p=1 -> T1 LRU: frame 2 (page 102)
    testing.expect_value(t, v2, u32(2))
    v3, _ := evict(arc) // |T1|=1 >= p=1 -> T1: frame 1 (page 103)
    testing.expect_value(t, v3, u32(1))
    v4, _ := evict(arc) // |T1|=0 < p -> T2: page 101's CURRENT frame
    testing.expect_value(t, v4, u32(3))
}

// C2: p must never wrap. p is u32 — repeated B2 hits at p=0 subtract from
// zero, and an unclamped `p -= delta` turns p into ~4 billion, silently
// flipping every future eviction to the wrong list. Walks p up, down past
// zero, and hammers the floor.
@(test)
test_c2_p_never_underflows :: proc(t: ^testing.T) {
    arc := new_arc(2)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    set_evictable(arc, 1, true)
    record_access(arc, 2, 102)
    set_evictable(arc, 2, true)

    // Track what each frame holds so every reload is a guaranteed ghost hit.
    held: map[u32]u32 = make(map[u32]u32)
    defer delete(held)
    held[1] = 101
    held[2] = 102

    for _ in 0 ..< 10 {
        victim, ok := evict(arc)
        testing.expect(t, ok)
        record_access(arc, victim, held[victim]) // ghost hit (B1 first, then B2s)
        set_evictable(arc, victim, true)
        testing.expect(t, arc.p <= arc.c, "p out of range: u32 underflow")
    }
    testing.expect_value(t, arc.p, u32(0)) // ends pinned to the floor
}

// C3: ghosts must be bounded. The directory (resident + ghosts) may never
// exceed 2c entries; churning many distinct pages through a tiny pool must
// not grow the ghost index without limit.
@(test)
test_c3_ghosts_are_bounded :: proc(t: ^testing.T) {
    arc := new_arc(2)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 1, 101) // keep some T2 presence so evictions ghost
    set_evictable(arc, 1, true)
    record_access(arc, 2, 102)
    set_evictable(arc, 2, true)

    for page in u32(500) ..< u32(540) {
        victim, ok := evict(arc)
        testing.expect(t, ok)
        record_access(arc, victim, page)
        set_evictable(arc, victim, true)
    }

    testing.expect(t, u32(len(arc.b1_index) + len(arc.b2_index)) <= 2 * arc.c,
        "ghost directory grew past 2c — ghosts are never trimmed")
}

// C4: fall-through between lists. The eviction rule picks T1, but T1's only
// entry is pinned — the victim must come from T2 rather than failing.
@(test)
test_c4_evict_falls_through_lists :: proc(t: ^testing.T) {
    arc := new_arc(2)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 1, 101) // -> T2, evictable
    set_evictable(arc, 1, true)
    record_access(arc, 2, 102) // -> T1, stays pinned

    // p=0 selects T1, but frame 2 is pinned. Must fall through to T2.
    v, ok := evict(arc)
    testing.expect(t, ok, "T2 had a candidate — fall through, don't fail")
    testing.expect_value(t, v, u32(1))
}

// C5: a capacity-1 pool. Degenerate sizes shake out off-by-ones in the
// eviction rule and ghost handling.
@(test)
test_c5_capacity_one :: proc(t: ^testing.T) {
    // NOTE: original version loaded a second page between evicting 101 and
    // re-accessing it — at c=1 the bound |T1|+|B1| <= c trims 101's ghost
    // first, so the expected B1 hit could never fire (authoring error, same
    // class as C1). At c=1 the only reachable B1 hit is evict-then-reload.
    arc := new_arc(1)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    set_evictable(arc, 1, true)
    v1, ok1 := evict(arc) // 101 -> B1
    testing.expect(t, ok1)
    testing.expect_value(t, v1, u32(1))

    record_access(arc, 1, 101) // immediate reload: B1 hit in a 1-frame pool
    testing.expect_value(t, arc.p, u32(1)) // p capped at c=1
    set_evictable(arc, 1, true)

    v2, ok2 := evict(arc) // |T1|=0 < p=1 -> T2; 101 -> B2
    testing.expect(t, ok2)
    testing.expect_value(t, v2, u32(1))

    record_access(arc, 1, 102) // new page -> T1
    set_evictable(arc, 1, true)
    v3, ok3 := evict(arc) // |T1|=1 >= p=1 -> T1; 102 -> B1
    testing.expect(t, ok3)
    testing.expect_value(t, v3, u32(1))

    record_access(arc, 1, 101) // B2 hit: p = max(0, 1 - max(1, 1/1)) = 0
    testing.expect_value(t, arc.p, u32(0)) // floor via the underflow guard
    set_evictable(arc, 1, true)

    v4, ok4 := evict(arc) // T1 empty -> fall through to T2
    testing.expect(t, ok4)
    testing.expect_value(t, v4, u32(1))
    testing.expect_value(t, arc_size(arc), u32(0))
}

// C6: unknown ids are silent no-ops, and the empty replacer stays sane.
@(test)
test_c6_unknown_ids :: proc(t: ^testing.T) {
    arc := new_arc(4)
    defer destroy_arc(arc)

    set_evictable(arc, 999, true) // never recorded
    testing.expect_value(t, arc_size(arc), u32(0))

    remove(arc, 999) // never recorded
    testing.expect_value(t, arc_size(arc), u32(0))

    _, ok := evict(arc)
    testing.expect(t, !ok)
}

// C7: fall through between lists. Opposite of C4. Eviction rule picks T2,
// but T2's only entry is pinned. Must fall through to T1.
@(test)
test_c7_evict_falls_through_lists_t2 :: proc(t: ^testing.T) {
    arc := new_arc(3)
    defer destroy_arc(arc)

    record_access(arc, 1, 101)
    record_access(arc, 2, 102)
    record_access(arc, 3, 103)
    set_evictable(arc, 1, true)
    set_evictable(arc, 2, true)
    set_evictable(arc, 3, true)

    // B1 hit 1 -> p = 1, page 101 -> T2
    v, _ := evict(arc)
    record_access(arc, 1, 101)

    // B1 hit 2 -> p = 2, page 102 -> T2
    v, _ = evict(arc)
    record_access(arc, 2, 102)

    // T1 = {3}, T2 = {1, 2}, p = 2
    v, _ = evict(arc)
    testing.expect_value(t, v, u32(3))
}
/*
*/ // ——— end of ladder gate ———
