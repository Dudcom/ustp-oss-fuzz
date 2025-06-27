#!/bin/bash -eu

# OSS-Fuzz build script for ustp-fuzz

# Install system dependencies 
apt-get update
apt-get install -y build-essential cmake pkg-config git libjson-c-dev

# Set up dependencies directory
DEPS_DIR="$PWD/deps"
mkdir -p "$DEPS_DIR"
cd "$DEPS_DIR"

# Clone and build libubox
if [ ! -d "libubox" ]; then
    echo "Downloading libubox..."
    git clone https://github.com/openwrt/libubox.git
    cd libubox
    rm -rf tests examples
    cd ..
fi

cd libubox
# Patch CMakeLists.txt to remove examples subdirectory reference
if [ -f CMakeLists.txt ]; then
    sed -i '/ADD_SUBDIRECTORY(examples)/d' CMakeLists.txt
    sed -i '/add_subdirectory(examples)/d' CMakeLists.txt
    sed -i '/ADD_SUBDIRECTORY.*examples/d' CMakeLists.txt
    sed -i '/add_subdirectory.*examples/d' CMakeLists.txt
fi
mkdir -p build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX="$DEPS_DIR/install" \
         -DCMAKE_C_FLAGS="$CFLAGS" \
         -DBUILD_LUA=OFF \
         -DBUILD_EXAMPLES=OFF \
         -DBUILD_TESTS=OFF \
         -DBUILD_STATIC=ON \
         -DBUILD_SHARED_LIBS=OFF
make -j$(nproc)
make install
cd "$DEPS_DIR"

# Clone and build libubus
if [ ! -d "ubus" ]; then
    echo "Downloading libubus..."
    git clone https://github.com/openwrt/ubus.git
    cd ubus
    rm -rf tests examples
    cd ..
fi

cd ubus
# Patch CMakeLists.txt to remove examples subdirectory reference
if [ -f CMakeLists.txt ]; then
    sed -i '/ADD_SUBDIRECTORY(examples)/d' CMakeLists.txt
    sed -i '/add_subdirectory(examples)/d' CMakeLists.txt
    sed -i '/ADD_SUBDIRECTORY.*examples/d' CMakeLists.txt
    sed -i '/add_subdirectory.*examples/d' CMakeLists.txt
fi
mkdir -p build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX="$DEPS_DIR/install" \
         -DCMAKE_C_FLAGS="$CFLAGS" \
         -DBUILD_LUA=OFF \
         -DBUILD_EXAMPLES=OFF \
         -DBUILD_TESTS=OFF \
         -DBUILD_STATIC=ON \
         -DBUILD_SHARED_LIBS=OFF \
         -DCMAKE_POSITION_INDEPENDENT_CODE=ON
make -j$(nproc)
make install

# Check if static library was created, if not create it manually
if [ ! -f "$DEPS_DIR/install/lib/libubus.a" ]; then
    echo "Creating static library for libubus..."
    ar rcs "$DEPS_DIR/install/lib/libubus.a" CMakeFiles/ubus.dir/*.o
fi

cd "$DEPS_DIR"

# Build libblobmsg_json (part of libubox but separate library)
if [ ! -f "$DEPS_DIR/install/lib/libblobmsg_json.a" ]; then
    echo "Building libblobmsg_json..."
    cd "$DEPS_DIR/libubox/build"
    # libblobmsg_json should be built as part of libubox
    if [ -f "libblobmsg_json.a" ]; then
        cp libblobmsg_json.a "$DEPS_DIR/install/lib/"
    fi
    cd "$DEPS_DIR"
fi

# Go to the ustp-oss-fuzz directory
cd "$SRC/ustp-fuzz"

# Set up environment variables
: "${CFLAGS:=-O2 -fPIC}"
: "${LDFLAGS:=}"
: "${PKG_CONFIG_PATH:=}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"

# Set up compiler flags
export PKG_CONFIG_PATH="$DEPS_DIR/install/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CFLAGS="$CFLAGS -I$DEPS_DIR/install/include -I."
export LDFLAGS="$LDFLAGS -L$DEPS_DIR/install/lib"
export CFLAGS="$CFLAGS -D_GNU_SOURCE -DDUMMY_MODE=1 -DDEBUG -std=gnu99"

# Create minimal headers for missing dependencies
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

echo "Compiling fuzzer..."
$CC $CFLAGS -c ustp-fuzz.c -o ustp-fuzz.o

echo "Linking fuzzer statically..."
# Link with full paths to static libraries to avoid linker issues
$CC $CFLAGS $LIB_FUZZING_ENGINE ustp-fuzz.o \
    bridge_track.o brmon.o hmac_md5.o libnetlink.o mstp.o \
    netif_utils.o packet.o worker.o config.o ubus.o log_impl.o \
    $DEPS_DIR/install/lib/libubox.a \
    $DEPS_DIR/install/lib/libubus.a \
    $DEPS_DIR/install/lib/libblobmsg_json.a \
    $LDFLAGS -ljson-c -lpthread \
    -o $OUT/ustp-fuzz

# Clean up object files
rm -f *.o

echo "Build completed successfully!"
echo "Fuzzer binary: $OUT/ustp-fuzz"
