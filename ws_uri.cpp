#include "ws_uri.hpp"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

/* ════════════════════════════════════════════════════════════════════════════
 * Why this file exists instead of the one-line std::regex it replaces
 * ════════════════════════════════════════════════════════════════════════════
 *
 * The old parser was:
 *
 *     std::regex re("^(.+?):?(\\d+)?(/.*)?$");
 *     if (std::regex_search(strHost, matches, re)) {
 *       strncpy(host, matches[1].str().c_str(), MAX_WS_URL_LEN);
 *       ...
 *       strncpy(path, matches[3].str().c_str(), MAX_PATH_LEN);
 *     }
 *
 * Three defects, in increasing severity:
 *
 *  1. `(.+?)` is lazy and `:?` makes the colon optional, so the host group can
 *     swallow colons. On anything with more than one colon (an unbracketed IPv6
 *     literal) the split is arbitrary rather than an error.
 *
 *  2. `strncpy(dst, src, N)` **does not NUL-terminate when strlen(src) >= N**.
 *     Both destinations are fixed-size stack buffers in the caller, so an
 *     over-long host or path left them unterminated and every later read ran
 *     off the end. Truncation is also silently accepted: half a hostname is a
 *     connection to the wrong place, not an error anybody sees.
 *
 *  3. Nothing rejected `..`, control characters, or whitespace.
 *
 * ⇒ Hand-rolled, explicit, and every rejection has a reason string. Over-long
 *   input is an ERROR here, never a truncation — the caller has no way to tell
 *   a truncated host from a short one.
 */

static const char *ERR_NONE = 0;

/* copy_checked writes src[0..len) plus a NUL, or fails if it would not fit. */
static int copy_checked(char *dst, size_t cap, const char *src, size_t len,
                        const char **err, const char *what) {
  if (len + 1 > cap) {
    *err = what;
    return 0;
  }
  memcpy(dst, src, len);
  dst[len] = '\0';
  return 1;
}

static int is_bad_char(unsigned char c) {
  /* Control characters and space break the HTTP request line. Reject rather
   * than percent-encode: these never appear in a legitimate fork URL, and
   * quietly rewriting the caller's input is worse than refusing it. */
  return c <= 0x20 || c == 0x7f;
}

int ws_uri_scheme(const char *uri, size_t *out_offset, int *out_secure,
                  unsigned int *out_port) {
  struct {
    const char *prefix;
    size_t len;
    int secure;
    unsigned int port;
  } schemes[] = {
      {"wss://", 6, 1, 443}, {"WSS://", 6, 1, 443},
      {"https://", 8, 1, 443}, {"HTTPS://", 8, 1, 443},
      {"ws://", 5, 0, 80},   {"WS://", 5, 0, 80},
      {"http://", 7, 0, 80}, {"HTTP://", 7, 0, 80},
  };
  size_t i;
  if (!uri) return 0;
  for (i = 0; i < sizeof(schemes) / sizeof(schemes[0]); i++) {
    if (0 == strncmp(uri, schemes[i].prefix, schemes[i].len)) {
      *out_offset = schemes[i].len;
      *out_secure = schemes[i].secure;
      *out_port = schemes[i].port;
      return 1;
    }
  }
  return 0;
}

int ws_uri_parse_authority(const char *in,
                           char *host, size_t hostcap,
                           char *path, size_t pathcap,
                           unsigned int *port,
                           const char **err) {
  const char *slash, *authority_end, *colon;
  size_t authority_len, host_len, path_len, i;

  *err = ERR_NONE;
  /* ★★★ Zero first — see the header. A caller that ignores our return value
   *     must not be able to read uninitialised stack memory. */
  if (hostcap) host[0] = '\0';
  if (pathcap) path[0] = '\0';

  if (!in || !*in) {
    *err = "empty authority";
    return 0;
  }
  if (hostcap < 2 || pathcap < 2) {
    *err = "destination buffers too small";
    return 0;
  }

  /* ── split authority / path at the first '/' ── */
  slash = strchr(in, '/');
  authority_end = slash ? slash : in + strlen(in);
  authority_len = (size_t)(authority_end - in);
  if (authority_len == 0) {
    *err = "missing host";
    return 0;
  }

  /* ── path ── */
  if (slash) {
    path_len = strlen(slash);
    for (i = 0; i < path_len; i++) {
      if (is_bad_char((unsigned char)slash[i])) {
        *err = "control character or space in path";
        return 0;
      }
    }
    /* Reject traversal outright. These paths are opaque routing keys
     * (/fork/<uuid>); nothing legitimate contains "..", and a server that
     * maps the path onto a filesystem should never see one from us. */
    if (strstr(slash, "..")) {
      *err = "path contains ..";
      return 0;
    }
    if (!copy_checked(path, pathcap, slash, path_len, err, "path too long")) {
      path[0] = '\0';
      return 0;
    }
  } else {
    path[0] = '/';
    path[1] = '\0';
  }

  /* ── host [+ optional port] ── */
  if (in[0] == '[') {
    /* Bracketed IPv6: [::1] or [::1]:9099 */
    const char *rb = (const char *)memchr(in, ']', authority_len);
    if (!rb) {
      *err = "unterminated IPv6 bracket";
      goto fail;
    }
    host_len = (size_t)(rb - in - 1);
    if (host_len == 0) {
      *err = "empty IPv6 literal";
      goto fail;
    }
    if (!copy_checked(host, hostcap, in + 1, host_len, err, "host too long")) {
      goto fail;
    }
    /* whatever follows ']' must be nothing or ":<digits>" */
    if (rb + 1 != authority_end) {
      if (rb[1] != ':') {
        *err = "junk after IPv6 bracket";
        goto fail;
      }
      colon = rb + 1;
      goto parse_port;
    }
    goto done;
  }

  /* ⚠ Unbracketed: more than one colon is ambiguous (an unbracketed IPv6
   *   literal). The old regex silently picked a split; we refuse. Getting this
   *   wrong means connecting somewhere other than where the operator wrote. */
  colon = 0;
  for (i = 0; i < authority_len; i++) {
    if (in[i] == ':') {
      if (colon) {
        *err = "multiple colons in host (bracket IPv6 literals)";
        goto fail;
      }
      colon = in + i;
    }
  }
  host_len = colon ? (size_t)(colon - in) : authority_len;
  if (host_len == 0) {
    *err = "missing host";
    goto fail;
  }
  for (i = 0; i < host_len; i++) {
    if (is_bad_char((unsigned char)in[i])) {
      *err = "control character or space in host";
      goto fail;
    }
  }
  if (!copy_checked(host, hostcap, in, host_len, err, "host too long")) {
    goto fail;
  }
  if (!colon) goto done;

parse_port : {
  const char *p = colon + 1;
  unsigned long v = 0;
  if (p >= authority_end) {
    *err = "empty port";
    goto fail;
  }
  for (; p < authority_end; p++) {
    if (!isdigit((unsigned char)*p)) {
      *err = "non-numeric port";
      goto fail;
    }
    v = v * 10 + (unsigned long)(*p - '0');
    if (v > 65535) {
      *err = "port out of range";
      goto fail;
    }
  }
  if (v == 0) {
    *err = "port 0";
    goto fail;
  }
  /* ★ Only now do we overwrite the caller's scheme default. */
  *port = (unsigned int)v;
}

done:
  return 1;

fail:
  host[0] = '\0';
  path[0] = '\0';
  return 0;
}
