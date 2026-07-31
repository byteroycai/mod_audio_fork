#ifndef __DROP_THROTTLE_H__
#define __DROP_THROTTLE_H__

#include <stdint.h>

/* PR-2: the report throttle for frames skipped on mutex contention.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * Why this three-line decision lives in its own header
 * ════════════════════════════════════════════════════════════════════════════
 *
 * ★★★ The counter cannot be observed end-to-end on this hardware. Measured:
 *
 *     6000 flooded `clearMarks` messages  → 0 skipped frames
 *     400 × 32KB flooded `playAudio`      → 0 skipped frames
 *
 *   The mutex is held for microseconds while fork_frame only retries every
 *   20ms, so the trylock simply never loses. That is consistent with S2'
 *   (0.03ms jitter at 10 concurrent sessions, no inflection point) — and it is
 *   exactly why PR-5/6/7 were dropped from the roadmap.
 *
 * ⇒ A test that REQUIRES contention would be permanently red here. What can be
 *   tested deterministically is the arithmetic: cumulative totals, the throttle
 *   interval, and the zero-guard. Those are the parts that can be silently
 *   wrong. Keeping them in a dependency-free header makes them unit-testable
 *   (tests/throttle_test.cpp) instead of assumed.
 *
 * ⚠⚠ This does NOT amount to "PR-2 is verified". Say it plainly:
 *   the counter has **never been observed firing on real contention**. It is
 *   verified by construction (unit-tested arithmetic + a source guard that the
 *   else-branch exists), not by observation. See tests/README.md.
 */

/* mod_af_should_report_drop decides whether this skipped frame warrants a report.
 *
 *   total         cumulative skipped frames, monotonic, never reset
 *   last_reported the value of `total` at the previous report
 *   every         report interval in frames; 0 means "use fallback"
 *   fallback      the compile-time default (FRAME_DROP_REPORT_EVERY)
 *
 * ★ `every == 0` must NOT mean "report every frame": at 50 frames/s × N
 *   sessions that turns the measurement into the bottleneck it is measuring.
 *   A caller that fails to initialise the field gets the fallback, not a storm.
 *
 * ★★ `total <= last_reported` is not just defensive. It is what makes the
 *   caller's "report, then set last_reported = total" sequence safe to repeat:
 *   without it, a second call with no new drops would report again.
 */
static inline int mod_af_should_report_drop(uint64_t total, uint64_t last_reported,
                                            uint64_t every, uint64_t fallback) {
  if (every == 0) every = fallback;
  if (every == 0) return 0; /* both zero: stay silent, never storm */
  if (total <= last_reported) return 0;
  return (total - last_reported) >= every;
}

#endif
