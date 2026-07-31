#ifndef __JSON_ESCAPE_H__
#define __JSON_ESCAPE_H__

#include <string>

/* PR-4: escape a string for embedding in a JSON double-quoted value.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * ★★★ What this replaces, and why "normally already true" was not enough
 * ════════════════════════════════════════════════════════════════════════════
 *
 * sendMarkEvent() built its frame by concatenation:
 *
 *     json << "{\"type\":\"mark\",\"data\":{\"name\":\"" << name << "\",...";
 *
 * with a comment saying the name is "passed through verbatim; callers are
 * responsible ... (the server is the source of these names so this is normally
 * already true)".
 *
 * ⚠ The server IS the source — which is precisely the problem: a name
 *   containing a `"` makes **our reply** malformed JSON, and the server then
 *   fails to parse a frame it caused. The failure surfaces on the far side of
 *   the wire from its cause, and "normally" is not a guarantee anybody checks.
 *   That is docs/CONSTRAINTS.md A11.
 *
 * ★ Pure and dependency-free on purpose: this is exactly the kind of code that
 *   needs a table of nasty inputs, and a translation unit that pulls in switch.h
 *   cannot be unit-tested. Same reasoning as ws_uri.cpp.
 *
 * ── What gets escaped ──
 *
 *   "  \  and the two-char forms \b \f \n \r \t   → their JSON escapes
 *   every other control char < 0x20                → \u00XX
 *   0x7f (DEL)                                     → 
 *
 * ⚠ Bytes >= 0x80 pass through UNTOUCHED. They are almost always UTF-8 (mark
 *   names come from operators and can be Chinese), and re-encoding them as \u
 *   escapes would require decoding UTF-8 correctly — more risk than value.
 *   ★ Invalid UTF-8 therefore still produces invalid JSON. That is a smaller
 *     hole than an unescaped quote and it is stated rather than assumed.
 */
static inline std::string json_escape(const std::string& in) {
  std::string out;
  out.reserve(in.size() + 8);
  static const char* HEX = "0123456789abcdef";
  for (std::string::size_type i = 0; i < in.size(); i++) {
    unsigned char c = (unsigned char) in[i];
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b";  break;
      case '\f': out += "\\f";  break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (c < 0x20 || c == 0x7f) {
          out += "\\u00";
          out += HEX[(c >> 4) & 0xf];
          out += HEX[c & 0xf];
        } else {
          out += (char) c;
        }
    }
  }
  return out;
}

#endif
