package main

import (
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/cockroachdb/swiss"
)

const (
	keySeed   = 0xDEADBEEF12345678
	missSeed  = 0xCAFEBABE87654321
	totalRuns = 12
	warmup    = 2
	measured  = totalRuns - warmup
)

func splitmix64(state *uint64) uint64 {
	*state += 0x9e3779b97f4a7c15
	z := *state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

var hexChars = []byte("0123456789abcdef")

func u64ToHex(val uint64, buf []byte) {
	for i := 15; i >= 0; i-- {
		buf[i] = hexChars[val&0xF]
		val >>= 4
	}
}

func median(arr []uint64) uint64 {
	s := make([]uint64, len(arr))
	copy(s, arr)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[len(s)/2]
}

func benchSwiss(n, fill, loadPct int) {
	keys := make([][16]byte, fill)
	missKeys := make([][16]byte, fill)
	ks := uint64(keySeed)
	ms := uint64(missSeed)
	for i := 0; i < fill; i++ {
		u64ToHex(splitmix64(&ks), keys[i][:])
		u64ToHex(splitmix64(&ms), missKeys[i][:])
	}

	// Shuffle
	order := make([]int, fill)
	for i := range order {
		order[i] = i
	}
	rng := uint64(42)
	for i := fill - 1; i > 0; i-- {
		j := int(splitmix64(&rng) % uint64(i+1))
		order[i], order[j] = order[j], order[i]
	}

	// Pre-allocate strings BEFORE timed loops (avoids GC during measurement)
	keyStrings := make([]string, fill)
	missStrings := make([]string, fill)
	for i := 0; i < fill; i++ {
		keyStrings[i] = string(keys[i][:])
		missStrings[i] = string(missKeys[i][:])
	}

	ins := make([]uint64, measured)
	lkp := make([]uint64, measured)
	del := make([]uint64, measured)
	mis := make([]uint64, measured)

	for r := 0; r < totalRuns; r++ {
		m := swiss.New[string, uint64](n)

		start := time.Now()
		for i := 0; i < fill; i++ {
			m.Put(keyStrings[i], uint64(i))
		}
		insertUs := uint64(time.Since(start).Microseconds())

		// Shuffled hit lookup
		start = time.Now()
		for i := 0; i < fill; i++ {
			ki := order[i]
			v, _ := m.Get(keyStrings[ki])
			_ = v
		}
		lookupUs := uint64(time.Since(start).Microseconds())

		// Shuffled miss lookup
		start = time.Now()
		for i := 0; i < fill; i++ {
			ki := order[i]
			_, ok := m.Get(missStrings[ki])
			_ = ok
		}
		missUs := uint64(time.Since(start).Microseconds())

		// Delete
		start = time.Now()
		for i := 0; i < fill/2; i++ {
			m.Delete(keyStrings[i])
		}
		deleteUs := uint64(time.Since(start).Microseconds())

		if r >= warmup {
			idx := r - warmup
			ins[idx] = insertUs
			lkp[idx] = lookupUs
			del[idx] = deleteUs
			mis[idx] = missUs
		}
	}

	fmt.Printf("RESULT\timpl=go-swiss\tn=%d\tload=%d\tinsert_us=%d\tlookup_us=%d\tmiss_us=%d\tdelete_us=%d\n",
		n, loadPct, median(ins), median(lkp), median(mis), median(del))
}

// Also benchmark Go's builtin map for comparison
func benchBuiltin(n, fill, loadPct int) {
	keys := make([][16]byte, fill)
	missKeys := make([][16]byte, fill)
	ks := uint64(keySeed)
	ms := uint64(missSeed)
	for i := 0; i < fill; i++ {
		u64ToHex(splitmix64(&ks), keys[i][:])
		u64ToHex(splitmix64(&ms), missKeys[i][:])
	}

	order := make([]int, fill)
	for i := range order {
		order[i] = i
	}
	rng := uint64(42)
	for i := fill - 1; i > 0; i-- {
		j := int(splitmix64(&rng) % uint64(i+1))
		order[i], order[j] = order[j], order[i]
	}

	keyStrings := make([]string, fill)
	missStrings := make([]string, fill)
	for i := 0; i < fill; i++ {
		keyStrings[i] = string(keys[i][:])
		missStrings[i] = string(missKeys[i][:])
	}

	ins := make([]uint64, measured)
	lkp := make([]uint64, measured)
	mis := make([]uint64, measured)
	del := make([]uint64, measured)

	for r := 0; r < totalRuns; r++ {
		m := make(map[string]uint64, n)

		start := time.Now()
		for i := 0; i < fill; i++ {
			m[keyStrings[i]] = uint64(i)
		}
		insertUs := uint64(time.Since(start).Microseconds())

		start = time.Now()
		for i := 0; i < fill; i++ {
			ki := order[i]
			v := m[keyStrings[ki]]
			_ = v
		}
		lookupUs := uint64(time.Since(start).Microseconds())

		start = time.Now()
		for i := 0; i < fill; i++ {
			ki := order[i]
			_, ok := m[missStrings[ki]]
			_ = ok
		}
		missUs := uint64(time.Since(start).Microseconds())

		start = time.Now()
		for i := 0; i < fill/2; i++ {
			delete(m, keyStrings[i])
		}
		deleteUs := uint64(time.Since(start).Microseconds())

		if r >= warmup {
			idx := r - warmup
			ins[idx] = insertUs
			lkp[idx] = lookupUs
			del[idx] = deleteUs
			mis[idx] = missUs
		}
	}

	fmt.Printf("RESULT\timpl=go-builtin\tn=%d\tload=%d\tinsert_us=%d\tlookup_us=%d\tmiss_us=%d\tdelete_us=%d\n",
		n, loadPct, median(ins), median(lkp), median(mis), median(del))
}

func main() {
	fmt.Fprintln(os.Stderr, "=== Go swiss.Map + builtin map benchmark ===")

	// Verify keys
	ks := uint64(keySeed)
	fmt.Fprint(os.Stderr, "First 3 keys: ")
	for i := 0; i < 3; i++ {
		v := splitmix64(&ks)
		var buf [16]byte
		u64ToHex(v, buf[:])
		fmt.Fprintf(os.Stderr, "%s ", string(buf[:]))
	}
	fmt.Fprintln(os.Stderr)

	// Load factor sweep at 1M
	pcts := []int{10, 25, 50, 75, 90, 99}
	for _, pct := range pcts {
		benchSwiss(1_048_576, 1_048_576*pct/100, pct)
	}
	for _, pct := range pcts {
		benchBuiltin(1_048_576, 1_048_576*pct/100, pct)
	}

	// Size sweep at 50% load
	sizes := []int{16_384, 65_536, 262_144, 1_048_576, 4_194_304}
	for _, s := range sizes {
		benchSwiss(s, s/2, 50)
	}
	for _, s := range sizes {
		benchBuiltin(s, s/2, 50)
	}

	fmt.Fprintln(os.Stderr, "DONE")
}
