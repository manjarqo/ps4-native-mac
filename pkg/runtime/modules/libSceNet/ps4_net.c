#include "ps4_net.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <sys/event.h>
#include <pthread.h>
#include <netdb.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>

#define ORBIS_OK 0
#define ORBIS_FAIL -1

static inline void *guest_to_host(GuestContext *ctx, uint64_t addr) {
    return addr ? (void *)(ctx->mem_base + addr) : NULL;
}

// Convert system errno to Orbis Net / POSIX errno
static int host_errno_to_orbis(int err) {
    return err; // macOS and FreeBSD share 1:1 BSD errno values for standard networking
}

static inline void set_net_errno(GuestContext *ctx, int err) {
    int oerr = host_errno_to_orbis(err);
    set_guest_errno(ctx, oerr);
}

void shim_sceNetInit(GuestContext *ctx) {
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

void shim_sceNetTerm(GuestContext *ctx) {
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

void shim_sceNetErrnoLoc(GuestContext *ctx) {
    if (ctx && ctx->fs_base) {
        ctx->rax = ctx->fs_base + 0x100ULL;
    } else {
        ctx->rax = 0;
    }
    SHIM_RETURN();
}

void shim_sceNetSocket(GuestContext *ctx) {
    const char *name = (const char *)guest_to_host(ctx, ctx->rdi);
    (void)name;
    int domain = (int)ctx->rsi;
    int type = (int)ctx->rdx;
    int protocol = (int)ctx->rcx;

    int ret = socket(domain, type, protocol);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = (uint64_t)ret;
    }
    SHIM_RETURN();
}

void shim_sceNetSocketClose(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    int ret = close(s);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetBind(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    const struct sockaddr *addr = (const struct sockaddr *)guest_to_host(ctx, ctx->rsi);
    socklen_t addrlen = (socklen_t)ctx->rdx;

    int ret = bind(s, addr, addrlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetListen(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    int backlog = (int)ctx->rsi;

    int ret = listen(s, backlog);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetAccept(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    struct sockaddr *addr = (struct sockaddr *)guest_to_host(ctx, ctx->rsi);
    socklen_t *addrlen = (socklen_t *)guest_to_host(ctx, ctx->rdx);

    int ret = accept(s, addr, addrlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = (uint64_t)ret;
    }
    SHIM_RETURN();
}

void shim_sceNetConnect(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    const struct sockaddr *addr = (const struct sockaddr *)guest_to_host(ctx, ctx->rsi);
    socklen_t addrlen = (socklen_t)ctx->rdx;

    int ret = connect(s, addr, addrlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetSend(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    const void *buf = guest_to_host(ctx, ctx->rsi);
    size_t len = (size_t)ctx->rdx;
    int flags = (int)ctx->rcx;

    ssize_t ret = send(s, buf, len, flags);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = (uint64_t)ret;
    }
    SHIM_RETURN();
}

void shim_sceNetRecv(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    void *buf = guest_to_host(ctx, ctx->rsi);
    size_t len = (size_t)ctx->rdx;
    int flags = (int)ctx->rcx;

    ssize_t ret = recv(s, buf, len, flags);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = (uint64_t)ret;
    }
    SHIM_RETURN();
}

void shim_sceNetSendto(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    const void *buf = guest_to_host(ctx, ctx->rsi);
    size_t len = (size_t)ctx->rdx;
    int flags = (int)ctx->rcx;
    const struct sockaddr *dest_addr = (const struct sockaddr *)guest_to_host(ctx, ctx->r8);
    socklen_t addrlen = (socklen_t)ctx->r9;

    ssize_t ret = sendto(s, buf, len, flags, dest_addr, addrlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = (uint64_t)ret;
    }
    SHIM_RETURN();
}

void shim_sceNetRecvfrom(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    void *buf = guest_to_host(ctx, ctx->rsi);
    size_t len = (size_t)ctx->rdx;
    int flags = (int)ctx->rcx;
    struct sockaddr *src_addr = (struct sockaddr *)guest_to_host(ctx, ctx->r8);
    socklen_t *addrlen = (socklen_t *)guest_to_host(ctx, ctx->r9);

    ssize_t ret = recvfrom(s, buf, len, flags, src_addr, addrlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = (uint64_t)ret;
    }
    SHIM_RETURN();
}

void shim_sceNetSetsockopt(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    int level = (int)ctx->rsi;
    int optname = (int)ctx->rdx;
    const void *optval = guest_to_host(ctx, ctx->rcx);
    socklen_t optlen = (socklen_t)ctx->r8;

    int ret = setsockopt(s, level, optname, optval, optlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetGetsockopt(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    int level = (int)ctx->rsi;
    int optname = (int)ctx->rdx;
    void *optval = guest_to_host(ctx, ctx->rcx);
    socklen_t *optlen = (socklen_t *)guest_to_host(ctx, ctx->r8);

    int ret = getsockopt(s, level, optname, optval, optlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetGetsockname(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    struct sockaddr *addr = (struct sockaddr *)guest_to_host(ctx, ctx->rsi);
    socklen_t *addrlen = (socklen_t *)guest_to_host(ctx, ctx->rdx);

    int ret = getsockname(s, addr, addrlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetGetpeername(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    struct sockaddr *addr = (struct sockaddr *)guest_to_host(ctx, ctx->rsi);
    socklen_t *addrlen = (socklen_t *)guest_to_host(ctx, ctx->rdx);

    int ret = getpeername(s, addr, addrlen);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetShutdown(GuestContext *ctx) {
    int s = (int)ctx->rdi;
    int how = (int)ctx->rsi;

    int ret = shutdown(s, how);
    if (ret < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

// Endian conversions
void shim_sceNetHtons(GuestContext *ctx) {
    uint16_t val = (uint16_t)ctx->rdi;
    ctx->rax = (uint64_t)htons(val);
    SHIM_RETURN();
}

void shim_sceNetHtonl(GuestContext *ctx) {
    uint32_t val = (uint32_t)ctx->rdi;
    ctx->rax = (uint64_t)htonl(val);
    SHIM_RETURN();
}

void shim_sceNetHtonll(GuestContext *ctx) {
    uint64_t val = ctx->rdi;
    // htonll / ntohll: swap if host is little-endian
    #if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    ctx->rax = __builtin_bswap64(val);
    #else
    ctx->rax = val;
    #endif
    SHIM_RETURN();
}

void shim_sceNetNtohs(GuestContext *ctx) {
    uint16_t val = (uint16_t)ctx->rdi;
    ctx->rax = (uint64_t)ntohs(val);
    SHIM_RETURN();
}

void shim_sceNetNtohl(GuestContext *ctx) {
    uint32_t val = (uint32_t)ctx->rdi;
    ctx->rax = (uint64_t)ntohl(val);
    SHIM_RETURN();
}

void shim_sceNetNtohll(GuestContext *ctx) {
    shim_sceNetHtonll(ctx);
}

void shim_sceNetInetPton(GuestContext *ctx) {
    int af = (int)ctx->rdi;
    const char *src = (const char *)guest_to_host(ctx, ctx->rsi);
    void *dst = guest_to_host(ctx, ctx->rdx);

    int ret = inet_pton(af, src, dst);
    if (ret <= 0) {
        set_net_errno(ctx, errno);
    }
    ctx->rax = (uint64_t)ret;
    SHIM_RETURN();
}

void shim_sceNetInetNtop(GuestContext *ctx) {
    int af = (int)ctx->rdi;
    const void *src = guest_to_host(ctx, ctx->rsi);
    char *dst = (char *)guest_to_host(ctx, ctx->rdx);
    socklen_t size = (socklen_t)ctx->rcx;

    const char *ret = inet_ntop(af, src, dst, size);
    if (!ret) {
        set_net_errno(ctx, errno);
        ctx->rax = 0;
    } else {
        ctx->rax = ctx->rdx;
    }
    SHIM_RETURN();
}

// Memory Pool
static int g_next_pool_id = 1;

void shim_sceNetPoolCreate(GuestContext *ctx) {
    const char *name = (const char *)guest_to_host(ctx, ctx->rdi);
    int size = (int)ctx->rsi;
    int flags = (int)ctx->rdx;
    (void)name; (void)size; (void)flags;

    ctx->rax = (uint64_t)(g_next_pool_id++);
    SHIM_RETURN();
}

void shim_sceNetPoolDestroy(GuestContext *ctx) {
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

// DNS Resolver
static int g_next_resolver_id = 1;

void shim_sceNetResolverCreate(GuestContext *ctx) {
    const char *name = (const char *)guest_to_host(ctx, ctx->rdi);
    int memid = (int)ctx->rsi;
    int flags = (int)ctx->rdx;
    (void)name; (void)memid; (void)flags;

    ctx->rax = (uint64_t)(g_next_resolver_id++);
    SHIM_RETURN();
}

void shim_sceNetResolverDestroy(GuestContext *ctx) {
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

void shim_sceNetResolverStartNtoa(GuestContext *ctx) {
    // int32_t sceNetResolverStartNtoa(rid, hostname, addr, timeout, retry, flags)
    const char *hostname = (const char *)guest_to_host(ctx, ctx->rsi);
    uint32_t *addr_out = (uint32_t *)guest_to_host(ctx, ctx->rdx);

    if (!hostname || !addr_out) {
        set_net_errno(ctx, EINVAL);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }

    struct hostent *he = gethostbyname(hostname);
    if (he && he->h_addr_list && he->h_addr_list[0]) {
        memcpy(addr_out, he->h_addr_list[0], sizeof(uint32_t));
        ctx->rax = ORBIS_OK;
    } else {
        set_net_errno(ctx, ENOENT);
        ctx->rax = (uint64_t)-1;
    }
    SHIM_RETURN();
}

void shim_sceNetResolverStartAton(GuestContext *ctx) {
    // Reverse DNS
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

void shim_sceNetResolverStartNtoaMultipleRecords(GuestContext *ctx) {
    shim_sceNetResolverStartNtoa(ctx);
}

// Epoll over kqueue. All calls on a kqueue use kevent64: the kernel refuses to mix it with
// kevent on one queue.
//
// A guest epoll id is the host kqueue descriptor; a guest socket id is the host socket
// descriptor (sceNetSocket returns the descriptor of socket(2)). SceNetEpollEvent is 24 bytes:
//   u32 events, u32 reserved, u64 ident, u64 data (union ptr/u32/s32/u64).
// The guest's data word is the udata of the registration's kevents and the events the guest
// asked for (IN/OUT bits) are kept in ext[0], so a registration needs no host-side
// bookkeeping. kqueue keeps read and write interest as two filters of one descriptor; a wait
// merges both into one event per descriptor. A registration that asks for neither IN nor OUT
// (only ERR/HUP) uses a read filter with an unreachable low-water mark: it never reports
// readable data, but still reports end-of-file and socket errors.
//
// Abort uses an EVFILT_USER event registered on the kqueue at creation (ident 0, EV_CLEAR;
// socket descriptors use the read/write filters, so there is no collision). A triggered
// event stays pending until a wait consumes it, which is the "preserve" behaviour; without
// the preserve flag Abort fails with ENOTBLK when no thread waits. Each kqueue descriptor
// below PS4_NET_EPOLL_TRACKED_FDS has a slot with its waiter count and the number of waiters
// that still have to be woken: a woken waiter triggers the event again for the next one.
#define PS4_NET_EPOLL_CTL_ADD 1
#define PS4_NET_EPOLL_CTL_MOD 2
#define PS4_NET_EPOLL_CTL_DEL 3
#define PS4_NET_EPOLLIN 0x1u
#define PS4_NET_EPOLLOUT 0x2u
#define PS4_NET_EPOLLERR 0x8u
#define PS4_NET_EPOLLHUP 0x10u
#define PS4_NET_EPOLL_ABORT_PRESERVE 0x1u
#define PS4_NET_DEBUG_NAME_LEN_MAX 31
#define PS4_NET_EPOLL_WAIT_BATCH 64
#define PS4_NET_EPOLL_TRACKED_FDS 4096

typedef struct Ps4NetEpollEvent {
    uint32_t events;
    uint32_t reserved;
    uint64_t ident;
    uint64_t data;
} Ps4NetEpollEvent;
_Static_assert(sizeof(Ps4NetEpollEvent) == 24, "SceNetEpollEvent is 24 bytes");

typedef struct EpollSlot {
    _Atomic int waiters;
    _Atomic int to_wake;
} EpollSlot;
static EpollSlot g_epoll_slots[PS4_NET_EPOLL_TRACKED_FDS];

static EpollSlot *epoll_slot(int epfd) {
    return epfd >= 0 && epfd < PS4_NET_EPOLL_TRACKED_FDS ? &g_epoll_slots[epfd] : NULL;
}

// Decrements without going below zero (a slot can be reset by a new epoll with the same fd).
static void epoll_dec(_Atomic int *v) {
    int cur = atomic_load(v);
    while (cur > 0 && !atomic_compare_exchange_weak(v, &cur, cur - 1)) {
    }
}

static bool epoll_is_kqueue(int fd) {
    // kevent64 with nothing to do succeeds on a kqueue and fails with EBADF on anything else.
    return fd >= 0 && kevent64(fd, NULL, 0, NULL, 0, 0, NULL) == 0;
}

static int epoll_check_epfd(int epfd) {
    return epoll_is_kqueue(epfd) ? 0 : EBADF;
}

static void epoll_trigger(int epfd) {
    struct kevent64_s wake;
    EV_SET64(&wake, 0, EVFILT_USER, 0, NOTE_TRIGGER, 0, 0, 0, 0);
    (void)kevent64(epfd, &wake, 1, NULL, 0, 0, NULL);
}

void shim_sceNetEpollCreate(GuestContext *ctx) {
    const char *name = (const char *)guest_to_host(ctx, ctx->rdi);
    int flags = (int)ctx->rsi;
    if (flags != 0) {
        set_net_errno(ctx, EINVAL);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }
    if (name && strnlen(name, PS4_NET_DEBUG_NAME_LEN_MAX + 1) > PS4_NET_DEBUG_NAME_LEN_MAX) {
        set_net_errno(ctx, ENAMETOOLONG);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }

    int kq = kqueue();
    if (kq < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }
    struct kevent64_s wake;
    EV_SET64(&wake, 0, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, 0, 0, 0);
    if (kevent64(kq, &wake, 1, NULL, 0, 0, NULL) < 0) {
        int err = errno;
        close(kq);
        set_net_errno(ctx, err);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }
    EpollSlot *slot = epoll_slot(kq);
    if (slot) {
        atomic_store(&slot->waiters, 0);
        atomic_store(&slot->to_wake, 0);
    }
    ctx->rax = (uint64_t)kq;
    SHIM_RETURN();
}

// Wakes every waiter, then closes. An id that is not an epoll is EBADF (nothing there) or EPERM
// (another descriptor).
void shim_sceNetEpollDestroy(GuestContext *ctx) {
    int epfd = (int)ctx->rdi;
    if (!epoll_is_kqueue(epfd)) {
        set_net_errno(ctx, (epfd >= 0 && fcntl(epfd, F_GETFD) >= 0) ? EPERM : EBADF);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }
    EpollSlot *slot = epoll_slot(epfd);
    if (slot) {
        // The woken waiters must not trigger again on a descriptor that is about to close, so
        // the trigger is repeated here until all have left (bounded: a waiter is a thread
        // inside kevent).
        atomic_store(&slot->to_wake, 0);
        for (int i = 0; i < 2000 && atomic_load(&slot->waiters) > 0; i++) {
            epoll_trigger(epfd);
            usleep(1000);
        }
    } else {
        epoll_trigger(epfd);
    }
    if (close(epfd) < 0) {
        set_net_errno(ctx, errno);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

// Applies one filter of a registration: adds or updates it when wanted, removes it when not.
// A filter that was not registered is not an error when removing. *existed is set when the
// filter was already registered (checked before the change). `mask` (the guest's IN/OUT bits)
// travels in ext[0]; `lowat_off` makes a read filter ignore data (error-only registrations).
static int epoll_set_filter(int epfd, int fd, int filter, bool want, uint64_t data, uint64_t mask, bool lowat_off,
                            bool *existed) {
    struct kevent64_s ch, rc;
    // Probe: a change with no action reports ENOENT for a filter that is not registered.
    EV_SET64(&ch, (uintptr_t)fd, filter, EV_RECEIPT, 0, 0, 0, 0, 0);
    if (kevent64(epfd, &ch, 1, &rc, 1, 0, NULL) != 1) {
        return errno ? errno : EINVAL;
    }
    *existed = (rc.flags & EV_ERROR) && rc.data == 0;
    if (!*existed && !((rc.flags & EV_ERROR) && rc.data == ENOENT)) {
        return (int)rc.data;
    }
    if (want) {
        EV_SET64(&ch, (uintptr_t)fd, filter, EV_ADD | EV_ENABLE | EV_RECEIPT, lowat_off ? NOTE_LOWAT : 0,
                 lowat_off ? 0x7fffffff : 0, data, mask, 0);
    } else if (*existed) {
        EV_SET64(&ch, (uintptr_t)fd, filter, EV_DELETE | EV_RECEIPT, 0, 0, 0, 0, 0);
    } else {
        return 0;
    }
    if (kevent64(epfd, &ch, 1, &rc, 1, 0, NULL) != 1) {
        return errno ? errno : EINVAL;
    }
    return (rc.flags & EV_ERROR) ? (int)rc.data : 0;
}

// int sceNetEpollControl(int eid, int op, int id, SceNetEpollEvent *event). Facts as on the
// console (shadPS4 libraries/net/net.cpp): DEL takes no event, ADD/MOD require one with at
// least one bit; an epoll id as the target is EPERM; an unknown id is EBADF; MOD of a
// descriptor that is not registered registers it; ADD of a registered one is EEXIST; DEL of
// one that is not registered is EBADF. Only IN and OUT select data readiness; a registration
// with just ERR/HUP bits is kept (so that DEL works) and reports only end-of-file and errors.
void shim_sceNetEpollControl(GuestContext *ctx) {
    int epfd = (int)ctx->rdi;
    int op = (int)ctx->rsi;
    int fd = (int)ctx->rdx;
    const Ps4NetEpollEvent *ev = (const Ps4NetEpollEvent *)guest_to_host(ctx, ctx->rcx);
    int err = 0;

    if (op < PS4_NET_EPOLL_CTL_ADD || op > PS4_NET_EPOLL_CTL_DEL || ((op == PS4_NET_EPOLL_CTL_DEL) != (ev == NULL))) {
        err = EINVAL;
    } else if (epoll_check_epfd(epfd) != 0 || fd < 0 || fcntl(fd, F_GETFD) < 0) {
        err = EBADF;
    } else if (epoll_is_kqueue(fd)) {
        err = EPERM;
    } else if (ev && ev->events == 0) {
        err = EINVAL;
    }
    if (err == 0) {
        uint64_t mask = ev ? (ev->events & (PS4_NET_EPOLLIN | PS4_NET_EPOLLOUT)) : 0;
        bool want_in = mask & PS4_NET_EPOLLIN;
        bool want_out = mask & PS4_NET_EPOLLOUT;
        // ERR/HUP only: keep a read filter that cannot see data.
        bool errors_only = ev && mask == 0;
        uint64_t data = ev ? ev->data : 0;
        bool had_in = false, had_out = false;
        if (op == PS4_NET_EPOLL_CTL_ADD) {
            // Refuse before adding. kqueue replaces the udata of a filter on every change, even
            // a probe, so a refused second ADD leaves the new data word on the registration
            // (the old one cannot be read back from a kqueue).
            struct kevent64_s ch[2], rc[2];
            EV_SET64(&ch[0], (uintptr_t)fd, EVFILT_READ, EV_RECEIPT, 0, 0, data, mask, 0);
            EV_SET64(&ch[1], (uintptr_t)fd, EVFILT_WRITE, EV_RECEIPT, 0, 0, data, mask, 0);
            if (kevent64(epfd, ch, 2, rc, 2, 0, NULL) != 2) {
                err = errno ? errno : EINVAL;
            } else if (rc[0].data == 0 || rc[1].data == 0) {
                err = EEXIST;
            }
        }
        if (err == 0) {
            err = epoll_set_filter(epfd, fd, EVFILT_READ, want_in || errors_only, data, mask, errors_only, &had_in);
        }
        if (err == 0) {
            err = epoll_set_filter(epfd, fd, EVFILT_WRITE, want_out, data, mask, false, &had_out);
        }
        if (err == 0 && op == PS4_NET_EPOLL_CTL_DEL && !had_in && !had_out) {
            err = EBADF;
        }
    }
    if (err) {
        set_net_errno(ctx, err);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

static uint64_t epoll_now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}

// int sceNetEpollWait(int eid, SceNetEpollEvent *events, int maxevents, int timeout_us).
// Returns the number of events, 0 on timeout, or -1 with errno: EBADF, EINVAL (no buffer,
// maxevents <= 0), EINTR (aborted by sceNetEpollAbort or the epoll was destroyed). A host
// signal interruption is retried with the time left. A negative timeout waits without limit.
// Reported bits: IN/OUT as asked at registration; HUP at end-of-file (peer closed or shut
// down); ERR in addition when the socket has an error (fflags holds it).
void shim_sceNetEpollWait(GuestContext *ctx) {
    int epfd = (int)ctx->rdi;
    Ps4NetEpollEvent *out = (Ps4NetEpollEvent *)guest_to_host(ctx, ctx->rsi);
    int maxevents = (int)ctx->rdx;
    int32_t timeout_us = (int32_t)ctx->rcx;

    if (epoll_check_epfd(epfd) != 0) {
        set_net_errno(ctx, EBADF);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }
    if (!out || maxevents <= 0) {
        set_net_errno(ctx, EINVAL);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }

    struct kevent64_s kev[PS4_NET_EPOLL_WAIT_BATCH];
    int want = maxevents > PS4_NET_EPOLL_WAIT_BATCH / 2 ? PS4_NET_EPOLL_WAIT_BATCH : maxevents * 2;
    uint64_t deadline_ns = timeout_us >= 0 ? epoll_now_ns() + (uint64_t)timeout_us * 1000ULL : 0;
    EpollSlot *slot = epoll_slot(epfd);
    if (slot) {
        atomic_fetch_add(&slot->waiters, 1);
    }
    int n, kerr;
    for (;;) {
        struct timespec ts, *tsp = NULL;
        if (timeout_us >= 0) {
            uint64_t now = epoll_now_ns();
            uint64_t left = now < deadline_ns ? deadline_ns - now : 0;
            ts.tv_sec = (time_t)(left / 1000000000ULL);
            ts.tv_nsec = (long)(left % 1000000000ULL);
            tsp = &ts;
        }
        n = kevent64(epfd, NULL, 0, kev, want, 0, tsp);
        kerr = errno;
        if (n < 0 && kerr == EINTR) {
            continue;
        }
        break;
    }
    bool woken = false;
    for (int i = 0; i < n; i++) {
        woken |= kev[i].filter == EVFILT_USER;
    }
    if (slot) {
        epoll_dec(&slot->waiters);
        if (woken) {
            // Pass the abort on to the next waiter that still has to be woken.
            int cur = atomic_load(&slot->to_wake);
            while (cur > 0 && !atomic_compare_exchange_weak(&slot->to_wake, &cur, cur - 1)) {
            }
            if (cur > 1) {
                epoll_trigger(epfd);
            }
        }
    }
    if (n < 0) {
        set_net_errno(ctx, kerr);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }
    if (woken) {
        set_net_errno(ctx, EINTR); // aborted (or destroyed)
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }

    int count = 0;
    for (int i = 0; i < n; i++) {
        uint32_t bits = 0;
        if (kev[i].filter == EVFILT_READ) {
            bits = (uint32_t)kev[i].ext[0] & PS4_NET_EPOLLIN;
        } else {
            bits = (uint32_t)kev[i].ext[0] & PS4_NET_EPOLLOUT;
        }
        if (kev[i].flags & EV_EOF) {
            bits |= PS4_NET_EPOLLHUP;
            if (kev[i].fflags != 0) {
                bits |= PS4_NET_EPOLLERR;
            }
        }
        if (bits == 0) {
            continue; // an error-only registration that saw plain data readiness
        }
        int j = 0;
        while (j < count && out[j].ident != (uint64_t)kev[i].ident) {
            j++;
        }
        if (j == count) {
            if (count == maxevents) {
                continue; // level-triggered: reported by the next wait
            }
            out[count].events = 0;
            out[count].reserved = 0;
            out[count].ident = (uint64_t)kev[i].ident;
            out[count].data = kev[i].udata;
            count++;
        }
        out[j].events |= bits;
    }
    ctx->rax = (uint64_t)count;
    SHIM_RETURN();
}

// int sceNetEpollAbort(int eid, int flags): makes every blocked sceNetEpollWait fail with
// EINTR. Flags: bit 0 keeps the abort for the next wait when nothing waits now; any other bit
// is EINVAL. Without that bit and without a waiter it fails with ENOTBLK.
void shim_sceNetEpollAbort(GuestContext *ctx) {
    int epfd = (int)ctx->rdi;
    uint32_t flags = (uint32_t)ctx->rsi;
    int err = 0;
    if (epoll_check_epfd(epfd) != 0) {
        err = EBADF;
    } else if ((flags & ~PS4_NET_EPOLL_ABORT_PRESERVE) != 0) {
        err = EINVAL;
    } else {
        EpollSlot *slot = epoll_slot(epfd);
        int waiting = slot ? atomic_load(&slot->waiters) : 1;
        if (waiting <= 0 && !(flags & PS4_NET_EPOLL_ABORT_PRESERVE)) {
            err = ENOTBLK;
        } else {
            if (slot) {
                atomic_store(&slot->to_wake, waiting > 0 ? waiting : 1);
            }
            epoll_trigger(epfd);
        }
    }
    if (err) {
        set_net_errno(ctx, err);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}

void shim_sceNetResolverGetError(GuestContext *ctx) {
    int resolverid = (int)ctx->rdi;
    int32_t *status = (int32_t *)guest_to_host(ctx, ctx->rsi);
    (void)resolverid;
    if (!status) {
        set_net_errno(ctx, EINVAL);
        ctx->rax = (uint64_t)-1;
        SHIM_RETURN();
    }
    *status = 0; // No error
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

void shim_sceNetGetMemoryPoolStats(GuestContext *ctx) {
    // Current memory pool stats
    void *currentStat = guest_to_host(ctx, ctx->rdi);
    (void)currentStat;
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

void shim_sceNetGetMacAddress(GuestContext *ctx) {
    unsigned char *mac = (unsigned char *)guest_to_host(ctx, ctx->rdi);
    int len = (int)ctx->rsi;
    if (mac && len >= 6) {
        // Return a valid fake PS4 NIC MAC address (e.g., 00:D9:D1:xx:xx:xx)
        mac[0] = 0x00;
        mac[1] = 0xD9;
        mac[2] = 0xD1;
        mac[3] = 0x12;
        mac[4] = 0x34;
        mac[5] = 0x56;
        ctx->rax = ORBIS_OK;
    } else {
        ctx->rax = (uint64_t)-1;
    }
    SHIM_RETURN();
}

void shim_sceNetGetSockInfo(GuestContext *ctx) {
    ctx->rax = ORBIS_OK;
    SHIM_RETURN();
}

// int sceNetEtherNtostr(const SceNetEtherAddr *n, char *str, size_t len)
//
// Formats a 6-byte Ethernet address as "%02x:%02x:%02x:%02x:%02x:%02x" (17 characters plus
// the terminator, SCE_NET_ETHER_ADDRSTRLEN = 18). Behaviour as in shadPS4
// (libraries/net/net.cpp sceNetEtherNtostr): a NULL address or buffer fails with EFAULT,
// a buffer shorter than 18 bytes with ENOSPC; both return -1 and set errno. Returns 0, or
// the errno value to report.
#define PS4_NET_ETHER_ADDRSTRLEN 18

int ps4_net_ether_ntostr(const uint8_t *addr, char *str, size_t len) {
    if (!addr || !str) return EFAULT;
    if (len < PS4_NET_ETHER_ADDRSTRLEN) return ENOSPC;
    snprintf(str, len, "%02x:%02x:%02x:%02x:%02x:%02x", addr[0], addr[1], addr[2], addr[3], addr[4], addr[5]);
    return 0;
}

void shim_sceNetEtherNtostr(GuestContext *ctx) {
    int err = ps4_net_ether_ntostr((const uint8_t *)guest_to_host(ctx, ctx->rdi), (char *)guest_to_host(ctx, ctx->rsi),
                                   (size_t)ctx->rdx);
    if (err) {
        set_net_errno(ctx, err);
        ctx->rax = (uint64_t)-1;
    } else {
        ctx->rax = ORBIS_OK;
    }
    SHIM_RETURN();
}
