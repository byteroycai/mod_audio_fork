/* Unit tests for the PR-4 JSON string escaper. */

#include "../json_escape.hpp"

#include <cstdio>
#include <string>

static int failures = 0;
static int checks = 0;

static void want(const std::string &got, const std::string &expect, const char *what) {
  checks++;
  if (got == expect) {
    std::printf("  \033[32mok\033[0m    %-44s -> %s\n", what, got.c_str());
    return;
  }
  std::printf("  \033[31mFAIL\033[0m  %-44s got [%s] want [%s]\n", what, got.c_str(),
              expect.c_str());
  failures++;
}

int main() {
  std::printf("json_escape\n");

  /* ★ 反证格 ①：普通名字必须**一个字节都不变**。
   *   一个"什么都转义"的实现会让下面所有恶意输入的断言通过，
   *   而正常的 mark 名字全被改写 —— 服务端认不出自己发过的名字。 */
  want(json_escape("after-greeting"), "after-greeting", "plain name unchanged");
  want(json_escape(""), "", "empty stays empty");
  want(json_escape("mark_1.step/2"), "mark_1.step/2", "punctuation unchanged");

  /* ── 真正会破坏 JSON 的 ── */
  want(json_escape("say \"hi\""), "say \\\"hi\\\"", "double quote");
  want(json_escape("back\\slash"), "back\\\\slash", "backslash");
  want(json_escape("a\nb"), "a\\nb", "newline");
  want(json_escape("a\rb"), "a\\rb", "carriage return");
  want(json_escape("a\tb"), "a\\tb", "tab");
  want(json_escape("a\bb"), "a\\bb", "backspace");
  want(json_escape("a\fb"), "a\\fb", "form feed");

  /* ★★ 这一个是最锐利的：一个 `"}` 结尾的名字能**提前闭合整个帧**，
   *   于是服务端解析到的是一个结构完全不同的对象。 */
  want(json_escape("x\",\"event\":\"forged"),
       "x\\\",\\\"event\\\":\\\"forged", "quote-comma injection is neutralised");

  /* ── 其余控制字符走 \u00XX ── */
  want(json_escape(std::string("a\x01""b")), "a\\u0001b", "0x01 -> \\u0001");
  want(json_escape(std::string("a\x1f""b")), "a\\u001fb", "0x1f -> \\u001f");
  want(json_escape(std::string("a\x7f""b")), "a\\u007fb", "0x7f (DEL) -> \\u007f");
  want(json_escape(std::string("\x00", 1) + "z"), "\\u0000z", "embedded NUL -> \\u0000");

  /* ★ 反证格 ②：>= 0x80 的字节必须原样透传（UTF-8 的中文 mark 名字）。
   *   ⚠ 若把它们也 \u 化，中文名字会变成一串转义而**看起来仍然合法** ——
   *     那种"能解析但不是原来那个字符串"的错误最难查。 */
  want(json_escape("开场白"), "开场白", "UTF-8 passes through untouched");
  want(json_escape("mix 中文 \"q\""), "mix 中文 \\\"q\\\"", "UTF-8 + quote");

  std::printf("\n");
  if (failures) {
    std::printf("\033[31m==> json_escape: %d/%d checks FAILED\033[0m\n", failures, checks);
    return 1;
  }
  if (checks < 15) {
    std::printf("\033[31m==> json_escape: only %d checks ran (expected >=15)\033[0m\n", checks);
    return 1;
  }
  std::printf("\033[32m==> json_escape: %d checks passed\033[0m\n", checks);
  return 0;
}
