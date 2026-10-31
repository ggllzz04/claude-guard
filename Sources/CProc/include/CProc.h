#ifndef C_GUARD_PROC_H
#define C_GUARD_PROC_H

#include <sys/types.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t pid;
    int32_t ppid;
    uid_t uid;
    gid_t gid;
    uint64_t start_usec; /* 进程启动时间；和 pid 一起唯一标识进程，防止 pid 复用后误杀 */
    char path[4096];
} guard_proc_info;

typedef struct {
    int32_t family;      /* AF_INET / AF_INET6 */
    int32_t protocol;    /* IPPROTO_TCP / IPPROTO_UDP */
    int32_t state;       /* tcpsi_state / soi_state */
    uint16_t local_port;
    uint16_t remote_port;
    char local_addr[64];
    char remote_addr[64];
} guard_socket_info;

int guard_list_pids(int32_t **pids, int32_t *count);
int guard_get_proc_info(int32_t pid, guard_proc_info *out);
int guard_list_sockets(int32_t pid, guard_socket_info **sockets, int32_t *count);
/* 读取进程的 argv，用空格连接写入 out（超长截断）；成功返回 0。 */
int guard_get_argv(int32_t pid, char *out, size_t out_len);
void guard_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif
