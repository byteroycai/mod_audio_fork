/* Unit tests for the PR-2 drop-report throttle.
 *
 * ★ These do NOT prove the counter fires on real contention — see the header.
 *   They prove the arithmetic, which is the part that can be silently wrong.
 */

#include "../drop_throttle.hpp"

#include <cstdio>

static int failures = 0;
static int checks = 0;

#define FALLBACK 500

static void want(int got, int expect, const char *what) {
  checks++;
  if (got == expect) {
    std::printf("  \033[32mok\033[0m    %s\n", what);
    return;
  }
  std::printf("  \033[31mFAIL\033[0m  %s (got %d, want %d)\n", what, got, expect);
  failures++;
}

int main() {
  std::printf("drop_throttle\n");

  /* ── the ordinary path ── */
  want(mod_af_should_report_drop(1, 0, 3, FALLBACK), 0, "1 drop, every=3 -> silent");
  want(mod_af_should_report_drop(2, 0, 3, FALLBACK), 0, "2 drops, every=3 -> silent");
  want(mod_af_should_report_drop(3, 0, 3, FALLBACK), 1, "3 drops, every=3 -> report");
  want(mod_af_should_report_drop(4, 0, 3, FALLBACK), 1, "4 drops, every=3 -> report");

  /* ── after a report, last_reported moves up ── */
  want(mod_af_should_report_drop(4, 3, 3, FALLBACK), 0, "1 new since report -> silent");
  want(mod_af_should_report_drop(6, 3, 3, FALLBACK), 1, "3 new since report -> report");

  /* ★★ Repeating the same call must stay silent. Without the
   *    `total <= last_reported` guard, a caller that reports and then re-checks
   *    would fire twice for the same drop. */
  want(mod_af_should_report_drop(6, 6, 3, FALLBACK), 0, "no new drops -> silent (idempotent)");
  want(mod_af_should_report_drop(5, 6, 3, FALLBACK), 0, "total below last_reported -> silent");

  /* ── the zero-guard ── */
  /* ★★★ every==0 must fall back, NOT report on every frame. At 50 fps × N
   *     sessions an event per drop makes the measurement the bottleneck. */
  want(mod_af_should_report_drop(1, 0, 0, FALLBACK), 0, "every=0 falls back to 500 -> silent at 1");
  want(mod_af_should_report_drop(FALLBACK, 0, 0, FALLBACK), 1, "every=0 falls back -> report at 500");
  want(mod_af_should_report_drop(1, 0, 0, 0), 0, "every=0 AND fallback=0 -> silent, never storm");
  want(mod_af_should_report_drop(1000000, 0, 0, 0), 0, "every=0 AND fallback=0 -> silent even at 1e6");

  /* ── every=1 is legal (a debugging setting) ── */
  want(mod_af_should_report_drop(1, 0, 1, FALLBACK), 1, "every=1 -> report every drop");
  want(mod_af_should_report_drop(1, 1, 1, FALLBACK), 0, "every=1, nothing new -> silent");

  /* ── no wrap-around surprises near the top of the range ── */
  {
    const uint64_t big = 0xFFFFFFFFFFFFFFF0ull;
    want(mod_af_should_report_drop(big + 3, big, 3, FALLBACK), 1, "near-max totals still compare");
    want(mod_af_should_report_drop(big + 1, big, 3, FALLBACK), 0, "near-max, below interval -> silent");
  }

  std::printf("\n");
  if (failures) {
    std::printf("\033[31m==> drop_throttle: %d/%d checks FAILED\033[0m\n", failures, checks);
    return 1;
  }
  /* ⚠ A suite that ran zero checks must not report success. */
  if (checks < 15) {
    std::printf("\033[31m==> drop_throttle: only %d checks ran (expected >=15)\033[0m\n", checks);
    return 1;
  }
  std::printf("\033[32m==> drop_throttle: %d checks passed\033[0m\n", checks);
  return 0;
}
