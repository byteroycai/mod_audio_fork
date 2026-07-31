/* Table-driven tests for the WebSocket URI parser (PR-1).
 *
 * No test framework on purpose: ws_uri.cpp has zero FreeSWITCH / libwebsockets
 * dependencies, so this compiles and runs standalone in a couple of seconds.
 * That is the whole reason the parser was split out of lws_glue.cpp — see
 * docs/CONSTRAINTS.md PR-1 ("URL 表驱动单测（纯函数最好测）").
 */

#include "../ws_uri.hpp"

#include <cstdio>
#include <cstring>
#include <string>

static int failures = 0;
static int checks = 0;

#define HOSTCAP 512
#define PATHCAP 4096

static void fail(const char *in, const char *what) {
  std::printf("  \033[31mFAIL\033[0m  %-46s  %s\n", in, what);
  failures++;
}

/* ok_case: must parse, and must produce exactly these values.
 *
 * ★★★ This is counter-proof ① from the plan. Without asserting the *values*,
 *     an implementation that rejects everything would pass every reject_case
 *     below and the suite would be green while the module could not connect
 *     anywhere.
 */
static void ok_case(const char *in, unsigned int port_in, const char *want_host,
                    unsigned int want_port, const char *want_path) {
  char host[HOSTCAP], path[PATHCAP];
  unsigned int port = port_in;
  const char *err = 0;
  checks++;
  if (!ws_uri_parse_authority(in, host, sizeof(host), path, sizeof(path), &port,
                              &err)) {
    fail(in, err ? err : "rejected but should parse");
    return;
  }
  if (std::strcmp(host, want_host) != 0) {
    fail(in, ("host=\"" + std::string(host) + "\" want \"" + want_host + "\"")
                 .c_str());
    return;
  }
  if (port != want_port) {
    char buf[96];
    std::snprintf(buf, sizeof(buf), "port=%u want %u", port, want_port);
    fail(in, buf);
    return;
  }
  if (std::strcmp(path, want_path) != 0) {
    fail(in, ("path=\"" + std::string(path) + "\" want \"" + want_path + "\"")
                 .c_str());
    return;
  }
  std::printf("  \033[32mok\033[0m    %-46s  host=%s port=%u path=%s\n", in,
              host, port, path);
}

/* reject_case: must be refused — and must leave the buffers zeroed.
 *
 * ★★★ Counter-proof ②. The zeroing is not cosmetic: mod_audio_fork.c used to
 *     log the failure and call start_capture() anyway with these very buffers
 *     uninitialised. Asserting host[0]=='\0' proves the *failure path* was
 *     rewritten, not just that a `return 0` was added somewhere.
 */
static void reject_case(const char *in, const char *why) {
  /* Pre-fill with junk so "the function left them alone" cannot look like
   * "the function zeroed them". */
  char host[HOSTCAP], path[PATHCAP];
  unsigned int port = 80;
  const char *err = 0;
  std::memset(host, 'Z', sizeof(host));
  std::memset(path, 'Z', sizeof(path));
  checks++;
  if (ws_uri_parse_authority(in, host, sizeof(host), path, sizeof(path), &port,
                             &err)) {
    fail(in, "parsed but should be rejected");
    return;
  }
  if (host[0] != '\0' || path[0] != '\0') {
    fail(in,
         "rejected but left host/path non-empty — a caller that ignores the "
         "return value would read uninitialised stack memory");
    return;
  }
  if (!err || !*err) {
    fail(in, "rejected without a reason string");
    return;
  }
  std::printf("  \033[32mok\033[0m    %-46s  rejected: %-34s (%s)\n", in, err,
              why);
}

int main() {
  std::printf("ws_uri: accepts\n");

  /* ── plain host, no port, no path ── */
  ok_case("10.0.0.5", 80, "10.0.0.5", 80, "/");
  /* ★ counter-proof ③: the scheme default must SURVIVE when no explicit port
   *   is given. An implementation that unconditionally writes a port would
   *   pass every other case here. */
  ok_case("10.0.0.5", 443, "10.0.0.5", 443, "/");

  /* ── explicit port ── */
  ok_case("10.0.0.5:9099", 80, "10.0.0.5", 9099, "/");
  ok_case("host.docker.internal:9099", 443, "host.docker.internal", 9099, "/");
  ok_case("h:1", 80, "h", 1, "/");
  ok_case("h:65535", 80, "h", 65535, "/");

  /* ── path ── */
  ok_case("10.0.0.5/fork/x", 80, "10.0.0.5", 80, "/fork/x");
  ok_case("10.0.0.5:9099/fork/abc-123", 80, "10.0.0.5", 9099, "/fork/abc-123");
  ok_case("h:9099/", 80, "h", 9099, "/");
  /* query strings ride along in the path — that is what lws wants */
  ok_case("h:9099/fork/x?a=1&b=2", 80, "h", 9099, "/fork/x?a=1&b=2");

  /* ── bracketed IPv6 ── */
  ok_case("[::1]", 80, "::1", 80, "/");
  ok_case("[::1]:9099", 80, "::1", 9099, "/");
  ok_case("[::1]:9099/fork/x", 80, "::1", 9099, "/fork/x");
  ok_case("[2001:db8::dead:beef]:443/x", 80, "2001:db8::dead:beef", 443, "/x");

  std::printf("\nws_uri: rejects\n");

  reject_case("", "empty");
  reject_case("/fork/x", "no host at all");
  reject_case(":9099", "port without host");
  reject_case("h:", "colon with no digits");
  reject_case("h:abc", "non-numeric port");
  reject_case("h:9099x", "trailing junk in port");
  reject_case("h:65536", "port above 65535");
  reject_case("h:0", "port 0");
  /* ⚠ The old lazy regex silently picked a split here and connected somewhere
   *   other than what the operator wrote. */
  reject_case("::1:9099", "unbracketed IPv6 — ambiguous");
  reject_case("[::1", "unterminated bracket");
  reject_case("[]", "empty IPv6 literal");
  reject_case("[]:80", "empty IPv6 literal with port");
  reject_case("[::1]x", "junk after bracket");
  reject_case("[::1]x:80", "junk between bracket and port");
  /* CONSTRAINTS PR-1 names this one explicitly. */
  reject_case("h/fork/../../etc/passwd", "path traversal");
  reject_case("h/..", "path traversal, bare");
  reject_case("h h:80", "space in host");
  reject_case("h:80/fo\tk", "tab in path");

  {
    /* over-long host: must be an ERROR, never a silent truncation.
     * ⚠ strncpy(dst, src, N) does not NUL-terminate when strlen(src) >= N —
     *   that is exactly what the old code did, on a fixed-size stack buffer. */
    std::string longhost(HOSTCAP + 10, 'a');
    reject_case(longhost.c_str(), "host longer than the destination buffer");
    std::string longpath = "h/" + std::string(PATHCAP + 10, 'b');
    reject_case(longpath.c_str(), "path longer than the destination buffer");
  }

  /* ── scheme splitting ── */
  std::printf("\nws_uri_scheme\n");
  struct {
    const char *uri;
    int want_ok, want_secure;
    unsigned int want_port;
    size_t want_off;
  } schemes[] = {
      {"ws://h", 1, 0, 80, 5},      {"WS://h", 1, 0, 80, 5},
      {"wss://h", 1, 1, 443, 6},    {"WSS://h", 1, 1, 443, 6},
      {"http://h", 1, 0, 80, 7},    {"https://h", 1, 1, 443, 8},
      {"tcp://h", 0, 0, 0, 0},      {"h:9099", 0, 0, 0, 0},
      {"", 0, 0, 0, 0},             {"wss:/h", 0, 0, 0, 0},
  };
  for (size_t i = 0; i < sizeof(schemes) / sizeof(schemes[0]); i++) {
    size_t off = 999;
    int secure = -1;
    unsigned int port = 0;
    int got = ws_uri_scheme(schemes[i].uri, &off, &secure, &port);
    checks++;
    if (got != schemes[i].want_ok) {
      fail(schemes[i].uri, got ? "accepted, want reject" : "rejected, want accept");
      continue;
    }
    if (got && (secure != schemes[i].want_secure || port != schemes[i].want_port ||
                off != schemes[i].want_off)) {
      char buf[160];
      std::snprintf(buf, sizeof(buf),
                    "secure=%d port=%u off=%zu want secure=%d port=%u off=%zu",
                    secure, port, off, schemes[i].want_secure,
                    schemes[i].want_port, schemes[i].want_off);
      fail(schemes[i].uri, buf);
      continue;
    }
    std::printf("  \033[32mok\033[0m    %-46s  %s\n", schemes[i].uri,
                got ? "parsed" : "rejected");
  }

  std::printf("\n");
  if (failures) {
    std::printf("\033[31m==> ws_uri: %d/%d checks FAILED\033[0m\n", failures,
                checks);
    return 1;
  }
  /* ⚠ A suite that ran zero checks must not report success — that is how a
   *   broken harness looks identical to a passing one. */
  if (checks < 40) {
    std::printf("\033[31m==> ws_uri: only %d checks ran (expected >=40) — "
                "the table did not execute\033[0m\n",
                checks);
    return 1;
  }
  std::printf("\033[32m==> ws_uri: %d checks passed\033[0m\n", checks);
  return 0;
}
