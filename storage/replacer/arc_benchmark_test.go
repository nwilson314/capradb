package replacer

import (
	"testing"
	"time"
)

// CMU threshold test: 262k ops per round should be < 3s
func TestARC_RecordAccessPerformance(t *testing.T) {
	const bpmSize = 256 << 10 // 262,144 frames
	const rounds = 10
	const maxAvgSeconds = 3.0

	arc := NewARC(uint32(bpmSize))

	// Fill up with lots of pages
	for i := uint32(0); i < bpmSize; i++ {
		arc.RecordAccess(i, i)
		arc.SetEvictable(i, true)
	}

	accessFrameID := uint32(256 << 9)
	var totalTime time.Duration

	for round := 0; round < rounds; round++ {
		start := time.Now()
		for i := uint32(0); i < bpmSize; i++ {
			arc.RecordAccess(accessFrameID, accessFrameID)
			accessFrameID = (accessFrameID + 1) % bpmSize
		}
		totalTime += time.Since(start)
	}

	avg := totalTime.Seconds() / rounds
	t.Logf("Average time per round (262k ops): %.3fs", avg)

	if avg >= maxAvgSeconds {
		t.Errorf("RecordAccess too slow: %.3fs avg (must be < %.1fs)", avg, maxAvgSeconds)
	}
}

// Micro-benchmark for per-op timing
func BenchmarkARC_RecordAccess(b *testing.B) {
	const bpmSize = 256 << 10

	arc := NewARC(uint32(bpmSize))

	for i := uint32(0); i < bpmSize; i++ {
		arc.RecordAccess(i, i)
		arc.SetEvictable(i, true)
	}

	accessFrameID := uint32(256 << 9)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		arc.RecordAccess(accessFrameID, accessFrameID)
		accessFrameID = (accessFrameID + 1) % bpmSize
	}
}
