#ifndef __WS_URI_H__
#define __WS_URI_H__

#include <stddef.h>

/* Pure WebSocket-URI parsing. **No FreeSWITCH, no libwebsockets includes.**
 *
 * That is deliberate: the parser is the part with all the edge cases, and a
 * translation unit that pulls in switch.h cannot be compiled standalone by a
 * unit test. Keeping it dependency-free is what makes tests/ws_uri_test.cpp
 * possible — see docs/CONSTRAINTS.md PR-1 ("URL 表驱动单测（纯函数最好测）").
 */

#ifdef __cplusplus
extern "C" {
#endif

/* ws_uri_scheme splits the scheme off a full URI.
 *
 *   out_offset  bytes to skip to reach the authority
 *   out_secure  1 for wss/https, 0 for ws/http
 *   out_port    the scheme's default port (443 or 80)
 *
 * Returns 1 on a recognised scheme, 0 otherwise.
 */
int ws_uri_scheme(const char *uri, size_t *out_offset, int *out_secure,
                  unsigned int *out_port);

/* ws_uri_parse_authority parses "host[:port][/path]" — scheme already stripped.
 *
 * On success returns 1 and:
 *   host   NUL-terminated, never truncated silently (over-long input is an error)
 *   path   NUL-terminated, "/" when the input carried none
 *   port   overwritten ONLY when the input carried an explicit port, so the
 *          caller's scheme default survives
 *
 * On failure returns 0, writes a short reason to *err (static string, never
 * NULL on failure), and **zeroes the first byte of host and path** so a caller
 * that ignores the return value cannot read uninitialised stack memory.
 *
 * ★★★ That zeroing is not belt-and-braces. mod_audio_fork.c used to log the
 *     parse failure and then call start_capture() anyway, with host/path being
 *     uninitialised stack buffers — see the comment at the call site.
 */
int ws_uri_parse_authority(const char *in,
                           char *host, size_t hostcap,
                           char *path, size_t pathcap,
                           unsigned int *port,
                           const char **err);

#ifdef __cplusplus
}
#endif

#endif
