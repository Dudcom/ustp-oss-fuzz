#!/bin/bash -eu

# OSS-Fuzz build script for ustp-fuzz

# Initialize PKG_CONFIG_PATH if not set
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

cd "$SRC"

# Clone and build json-c (required by libubox)
if [ ! -d "json-c" ]; then
    git clone https://github.com/json-c/json-c.git
fi

cd json-c
mkdir -p build
cd build

cmake .. \
    -DCMAKE_INSTALL_PREFIX="$SRC/json-c-install" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_SHARED_LIBS=OFF

make -j$(nproc)
make install

cd "$SRC"

# Clone and build libubox
if [ ! -d "libubox" ]; then
    git clone https://git.openwrt.org/project/libubox.git
fi

cd libubox
mkdir -p build
cd build

# Configure libubox without LUA, with json-c
PKG_CONFIG_PATH="$SRC/json-c-install/lib/pkgconfig:$PKG_CONFIG_PATH" \
cmake .. \
    -DCMAKE_INSTALL_PREFIX="$SRC/libubox-install" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DCMAKE_PREFIX_PATH="$SRC/json-c-install"

make -j$(nproc)
make install

cd "$SRC"

# Clone and build libubus  
if [ ! -d "libubus" ]; then
    git clone https://git.openwrt.org/project/libubus.git
fi

cd libubus
mkdir -p build
cd build

# Configure libubus without LUA
PKG_CONFIG_PATH="$SRC/json-c-install/lib/pkgconfig:$SRC/libubox-install/lib/pkgconfig:$PKG_CONFIG_PATH" \
cmake .. \
    -DCMAKE_INSTALL_PREFIX="$SRC/libubus-install" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LUA=OFF \
    -DBUILD_EXAMPLES=OFF \
    -Dlibubox_include_dir="$SRC/libubox-install/include" \
    -Dlibubox_library="$SRC/libubox-install/lib/libubox.a" \
    -DCMAKE_PREFIX_PATH="$SRC/json-c-install;$SRC/libubox-install"

make -j$(nproc)
make install

cd "$SRC/ustp-oss-fuzz"

# Set up compiler flags
export CFLAGS="$CFLAGS -I$SRC/libubox-install/include -I$SRC/libubus-install/include -I$SRC/json-c-install/include -I."
export CXXFLAGS="$CXXFLAGS -I$SRC/libubox-install/include -I$SRC/libubus-install/include -I$SRC/json-c-install/include -I."

# Create minimal log.h if it doesn't exist
cat > log.h << 'EOF'
#ifndef LOG_H
#define LOG_H

#include <stdio.h>

#define LOG_LEVEL_DEFAULT 3
#define LOG_LEVEL_MAX 5
#define LOG_LEVEL_INFO 3
#define LOG_LEVEL_STATE_MACHINE_TRANSITION 4

#define ERROR(fmt, ...) do { fprintf(stderr, "ERROR: " fmt "\n", ##__VA_ARGS__); } while(0)
#define INFO(fmt, ...) do { fprintf(stdout, "INFO: " fmt "\n", ##__VA_ARGS__); } while(0)
#define LOG(fmt, ...) do { fprintf(stdout, "LOG: " fmt "\n", ##__VA_ARGS__); } while(0)
#define PRINT(level, fmt, ...) do { if (level <= LOG_LEVEL_DEFAULT) printf(fmt "\n", ##__VA_ARGS__); } while(0)

#define TSTM(x, r, fmt, ...) do { if (!(x)) { ERROR(fmt, ##__VA_ARGS__); return r; } } while(0)
#define TST(x, r) do { if (!(x)) return r; } while(0)

extern int log_level;

#endif
EOF

# Create minimal driver.h
cat > driver.h << 'EOF'
#ifndef _MSTP_DRIVER_H
#define _MSTP_DRIVER_H

#include "mstp.h"

static inline int driver_set_new_state(per_tree_port_t *ptp, int new_state) {
    return new_state;
}

static inline void driver_flush_all_fids(per_tree_port_t *ptp) {
    MSTP_IN_all_fids_flushed(ptp);
}

static inline unsigned int driver_set_ageing_time(port_t *prt, unsigned int ageingTime) {
    return ageingTime;
}

static inline bool driver_create_msti(bridge_t *br, __u16 mstid) {
    return true;
}

static inline bool driver_delete_msti(bridge_t *br, __u16 mstid) {
    return true;
}

static inline bool driver_create_bridge(bridge_t *br, __u8 *macaddr) {
    return true;
}

static inline bool driver_create_port(port_t *prt, __u16 portno) {
    return true;
}

static inline void driver_delete_bridge(bridge_t *br) {
}

static inline void driver_delete_port(port_t *prt) {
}

#endif
EOF

# Create minimal packet.h
cat > packet.h << 'EOF'
#ifndef PACKET_H
#define PACKET_H

#include <stdint.h>
#include <sys/types.h>

void packet_rcv(void);
int packet_send(int if_index, struct iovec *iov, int iov_count, int len);
int packet_sock_init(void);

#endif
EOF

# Create minimal libnetlink.h
cat > libnetlink.h << 'EOF'
#ifndef LIBNETLINK_H
#define LIBNETLINK_H

#include <linux/netlink.h>
#include <linux/rtnetlink.h>

struct rtnl_handle {
    int fd;
    struct sockaddr_nl local;
    struct sockaddr_nl peer;
    __u32 seq;
    __u32 dump;
};

typedef int (*rtnl_filter_t)(const struct sockaddr_nl *, struct nlmsghdr *n, void *);

int rtnl_open(struct rtnl_handle *rth, unsigned subscriptions);
int rtnl_listen(struct rtnl_handle *rtnl, rtnl_filter_t handler, void *jarg);
int rtnl_talk(struct rtnl_handle *rtnl, struct nlmsghdr *n, pid_t peer,
              unsigned groups, struct nlmsghdr *answer,
              rtnl_filter_t junk, void *jarg);
int rtnl_wilddump_request(struct rtnl_handle *rth, int family, int type);
int rtnl_dump_filter(struct rtnl_handle *rth, rtnl_filter_t filter,
                     void *arg1, rtnl_filter_t junk, void *arg2);
void parse_rtattr(struct rtattr *tb[], int max, struct rtattr *rta, int len);
int addattr8(struct nlmsghdr *n, int maxlen, int type, __u8 data);

extern struct rtnl_handle rth_state;

#endif
EOF

echo "Building USTP object files..."

# Build all the source files from CMakeLists.txt (except main.c)
$CC $CFLAGS -c bridge_track.c -o bridge_track.o
$CC $CFLAGS -c hmac_md5.c -o hmac_md5.o
$CC $CFLAGS -c mstp.c -o mstp.o
$CC $CFLAGS -c netif_utils.c -o netif_utils.o
$CC $CFLAGS -c worker.c -o worker.o
$CC $CFLAGS -c config.c -o config.o

# Create simplified versions of files that depend on kernel interfaces
cat > brmon_minimal.c << 'EOF'
#include "bridge_ctl.h"
#include "worker.h"
#include <stdio.h>

void bridge_event_handler(void) {
    // Minimal implementation for fuzzing
}

int init_bridge_ops(void) {
    return 0;
}

int bridge_notify(int br_index, int if_index, bool newlink, unsigned flags) {
    return 0;
}
EOF
$CC $CFLAGS -c brmon_minimal.c -o brmon.o

cat > libnetlink_minimal.c << 'EOF'
#include "libnetlink.h"
#include <string.h>
#include <stdlib.h>

struct rtnl_handle rth_state;

int rtnl_open(struct rtnl_handle *rth, unsigned subscriptions) {
    memset(rth, 0, sizeof(*rth));
    rth->fd = -1;
    return 0;
}

int rtnl_listen(struct rtnl_handle *rtnl, rtnl_filter_t handler, void *jarg) {
    return 0;
}

int rtnl_talk(struct rtnl_handle *rtnl, struct nlmsghdr *n, pid_t peer,
              unsigned groups, struct nlmsghdr *answer,
              rtnl_filter_t junk, void *jarg) {
    return 0;
}

int rtnl_wilddump_request(struct rtnl_handle *rth, int family, int type) {
    return 0;
}

int rtnl_dump_filter(struct rtnl_handle *rth, rtnl_filter_t filter,
                     void *arg1, rtnl_filter_t junk, void *arg2) {
    return 0;
}

void parse_rtattr(struct rtattr *tb[], int max, struct rtattr *rta, int len) {
}

int addattr8(struct nlmsghdr *n, int maxlen, int type, __u8 data) {
    return 0;
}
EOF
$CC $CFLAGS -c libnetlink_minimal.c -o libnetlink.o

cat > packet_minimal.c << 'EOF'
#include "packet.h"
#include "worker.h"
#include <stdio.h>

void packet_rcv(void) {
    // Minimal implementation for fuzzing
}

int packet_send(int if_index, struct iovec *iov, int iov_count, int len) {
    return len;
}

int packet_sock_init(void) {
    return 0;
}
EOF
$CC $CFLAGS -c packet_minimal.c -o packet.o

cat > ubus_minimal.c << 'EOF'
#include "ubus.h"

void ustp_ubus_init(void) {
    // Minimal implementation for fuzzing
}

void ustp_ubus_exit(void) {
    // Minimal implementation for fuzzing  
}
EOF
$CC $CFLAGS -c ubus_minimal.c -o ubus.o

# Create log implementation
cat > log_impl.c << 'EOF'
#include "log.h"
#include <stdarg.h>
#include <stdio.h>

int log_level = LOG_LEVEL_DEFAULT;

void Dprintf(int level, const char *fmt, ...) {
    if (level > log_level) return;
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
}
EOF
$CC $CFLAGS -c log_impl.c -o log_impl.o

# Build the fuzzer
echo "Building fuzzer..."
$CC $CFLAGS $LIB_FUZZING_ENGINE ustp-fuzz.c \
    bridge_track.o brmon.o hmac_md5.o libnetlink.o mstp.o \
    netif_utils.o packet.o worker.o config.o ubus.o log_impl.o \
    -L"$SRC/libubox-install/lib" -L"$SRC/libubus-install/lib" -L"$SRC/json-c-install/lib" \
    -lubox -lubus -ljson-c -lpthread \
    -o $OUT/ustp-fuzz

echo "Build completed successfully!"
