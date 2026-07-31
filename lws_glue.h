#ifndef __LWS_GLUE_H__
#define __LWS_GLUE_H__

#include "mod_audio_fork.h"

int parse_ws_uri(switch_channel_t *channel, const char* szServerUri, char* host, char *path, unsigned int* pPort, int* pSslFlags);

/* PR-3: read back what the module actually configured itself with.
 *
 * ★ These are the **effective** values (after the env clamp), not what the env
 *   asked for. `audio_fork_version` reports them so an operator can see the
 *   difference: MOD_AUDIO_FORK_SERVICE_THREADS=9 clamps to 5, and finding that
 *   out from a log line at startup is not the same as being able to ask.
 */
/* ⚠ 名字不能叫 fork_service_threads —— :32 那个已经被占了（它是 lws 服务循环的
 *   启动器，由 mod_runtime 调，签名是 (int*)）。★ 撞名的症状是 C 编译器报
 *   `conflicting types`，而那个报错指向我的声明行，读起来像我写错了类型。
 */
int fork_effective_threads(void);
const char* fork_effective_subprotocol(void);

switch_status_t fork_init();
switch_status_t fork_cleanup();
switch_status_t fork_session_init(switch_core_session_t *session, responseHandler_t responseHandler,
		uint32_t samples_per_second, char *host, unsigned int port, char* path, int sampling, int sslFlags, int channels,
    char *bugname, char* metadata,
    int bidirectional_audio_enable, int bidirectional_audio_stream, int bidirectional_audio_sample_rate,
    void **ppUserData);
switch_status_t fork_session_cleanup(switch_core_session_t *session, char *bugname, char* text, int channelIsClosing);
switch_status_t fork_session_pauseresume(switch_core_session_t *session, char *bugname, int pause);
switch_status_t fork_session_stop_play(switch_core_session_t *session, char *bugname);
switch_status_t fork_session_graceful_shutdown(switch_core_session_t *session, char *bugname);
switch_status_t fork_session_send_text(switch_core_session_t *session, char *bugname, char* text);
switch_bool_t fork_frame(switch_core_session_t *session, switch_media_bug_t *bug);
switch_bool_t dub_speech_frame(switch_media_bug_t *bug, private_t *tech_pvt);
switch_status_t fork_service_threads();
switch_status_t fork_session_connect(void **ppUserData);
#endif
