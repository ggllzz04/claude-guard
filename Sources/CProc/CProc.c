#include "CProc.h"

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int guard_list_pids(int32_t **pids, int32_t *count) {
    if (!pids || !count) return -1;
    *pids = NULL;
    *count = 0;

    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return -1;

    int capacity = n + 32;
    int32_t *buffer = (int32_t *)calloc((size_t)capacity, sizeof(int32_t));
    if (!buffer) return -1;

    int got = proc_listallpids(buffer, capacity * (int)sizeof(int32_t));
    if (got < 0) {
        free(buffer);
        return -1;
    }

    *pids = buffer;
    *count = got;
    return 0;
}

int guard_get_proc_info(int32_t pid, guard_proc_info *out) {
    if (!out || pid <= 0) return -1;
    memset(out, 0, sizeof(*out));

    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    int r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd));
    if (r <= 0) return -1;

    out->pid = (int32_t)bsd.pbi_pid;
    out->ppid = (int32_t)bsd.pbi_ppid;
    out->uid = bsd.pbi_uid;
    out->gid = bsd.pbi_gid;
    out->start_usec = (uint64_t)bsd.pbi_start_tvsec * 1000000ULL + (uint64_t)bsd.pbi_start_tvusec;

    char path[PROC_PIDPATHINFO_MAXSIZE];
    memset(path, 0, sizeof(path));
    int len = proc_pidpath(pid, path, (uint32_t)sizeof(path));
    if (len > 0) {
        strncpy(out->path, path, sizeof(out->path) - 1);
    }
    return 0;
}

static void copy_addr(int family, const struct in_sockinfo *ini,
                      char *local, size_t local_len,
                      char *remote, size_t remote_len) {
    local[0] = '\0';
    remote[0] = '\0';

    if (family == AF_INET || (ini->insi_vflag & INI_IPV4)) {
        struct in_addr la = ini->insi_laddr.ina_46.i46a_addr4;
        struct in_addr ra = ini->insi_faddr.ina_46.i46a_addr4;
        inet_ntop(AF_INET, &la, local, (socklen_t)local_len);
        inet_ntop(AF_INET, &ra, remote, (socklen_t)remote_len);
    } else if (family == AF_INET6 || (ini->insi_vflag & INI_IPV6)) {
        struct in6_addr la = ini->insi_laddr.ina_6;
        struct in6_addr ra = ini->insi_faddr.ina_6;
        inet_ntop(AF_INET6, &la, local, (socklen_t)local_len);
        inet_ntop(AF_INET6, &ra, remote, (socklen_t)remote_len);
    }
}

int guard_list_sockets(int32_t pid, guard_socket_info **sockets, int32_t *count) {
    if (!sockets || !count || pid <= 0) return -1;
    *sockets = NULL;
    *count = 0;

    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) {
        return 0;
    }

    int capacity = bytes / (int)sizeof(struct proc_fdinfo) + 16;
    struct proc_fdinfo *fds = (struct proc_fdinfo *)calloc((size_t)capacity, sizeof(struct proc_fdinfo));
    if (!fds) return -1;

    int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, capacity * (int)sizeof(struct proc_fdinfo));
    if (got <= 0) {
        free(fds);
        return 0;
    }

    int fd_count = got / (int)sizeof(struct proc_fdinfo);
    int out_cap = 32;
    int out_count = 0;
    guard_socket_info *out = (guard_socket_info *)calloc((size_t)out_cap, sizeof(guard_socket_info));
    if (!out) {
        free(fds);
        return -1;
    }

    for (int i = 0; i < fd_count; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;

        struct socket_fdinfo si;
        memset(&si, 0, sizeof(si));
        int r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, (int)sizeof(si));
        if (r <= 0) continue;

        int family = si.psi.soi_family;
        if (family != AF_INET && family != AF_INET6) continue;

        guard_socket_info item;
        memset(&item, 0, sizeof(item));
        item.family = family;

        const struct in_sockinfo *ini = NULL;
        if (si.psi.soi_kind == SOCKINFO_TCP) {
            ini = &si.psi.soi_proto.pri_tcp.tcpsi_ini;
            item.protocol = IPPROTO_TCP;
            item.state = si.psi.soi_proto.pri_tcp.tcpsi_state;
        } else if (si.psi.soi_kind == SOCKINFO_IN) {
            ini = &si.psi.soi_proto.pri_in;
            item.protocol = IPPROTO_UDP;
            item.state = si.psi.soi_state;
        } else {
            continue;
        }

        item.local_port = ntohs((uint16_t)ini->insi_lport);
        item.remote_port = ntohs((uint16_t)ini->insi_fport);
        copy_addr(family, ini, item.local_addr, sizeof(item.local_addr),
                  item.remote_addr, sizeof(item.remote_addr));

        if (out_count >= out_cap) {
            out_cap *= 2;
            guard_socket_info *grown = (guard_socket_info *)realloc(out, (size_t)out_cap * sizeof(guard_socket_info));
            if (!grown) {
                free(out);
                free(fds);
                return -1;
            }
            out = grown;
        }
        out[out_count++] = item;
    }

    free(fds);
    if (out_count == 0) {
        free(out);
        return 0;
    }
    *sockets = out;
    *count = out_count;
    return 0;
}

int guard_get_argv(int32_t pid, char *out, size_t out_len) {
    if (!out || out_len == 0 || pid <= 0) return -1;
    out[0] = '\0';

    int argmax = 0;
    size_t size = sizeof(argmax);
    int mib_argmax[2] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(mib_argmax, 2, &argmax, &size, NULL, 0) != 0 || argmax <= 0) return -1;

    char *buffer = (char *)malloc((size_t)argmax);
    if (!buffer) return -1;
    size = (size_t)argmax;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0 || size < sizeof(int)) {
        free(buffer);
        return -1;
    }

    /* 布局：argc | exec_path \0... | argv[0..argc) | envp... */
    int argc = 0;
    memcpy(&argc, buffer, sizeof(argc));
    char *p = buffer + sizeof(argc);
    char *end = buffer + size;
    while (p < end && *p) p++;
    while (p < end && !*p) p++;

    size_t used = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t len = strnlen(p, (size_t)(end - p));
        if (used > 0 && used + 1 < out_len) out[used++] = ' ';
        size_t room = out_len - 1 - used;
        size_t copy = len < room ? len : room;
        memcpy(out + used, p, copy);
        used += copy;
        p += len + 1;
        if (used + 1 >= out_len) break;
    }
    out[used] = '\0';
    free(buffer);
    return 0;
}

void guard_free(void *ptr) {
    free(ptr);
}
