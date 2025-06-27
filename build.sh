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

# Go to the ustp-fuzz directory
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

echo "Building USTP object files..."

# Build all the actual source files from the project (except main.c)
$CC $CFLAGS -c bridge_track.c -o bridge_track.o
$CC $CFLAGS -c brmon.c -o brmon.o
$CC $CFLAGS -c hmac_md5.c -o hmac_md5.o
$CC $CFLAGS -c libnetlink.c -o libnetlink.o
$CC $CFLAGS -c mstp.c -o mstp.o
$CC $CFLAGS -c netif_utils.c -o netif_utils.o
$CC $CFLAGS -c packet.c -o packet.o
$CC $CFLAGS -c worker.c -o worker.o
$CC $CFLAGS -c config.c -o config.o
$CC $CFLAGS -c ubus.c -o ubus.o

echo "Compiling fuzzer..."
$CC $CFLAGS -c ustp-fuzz.c -o ustp-fuzz.o

echo "Linking fuzzer statically..."
# Link with full paths to static libraries to avoid linker issues
$CC $CFLAGS $LIB_FUZZING_ENGINE ustp-fuzz.o \
    bridge_track.o brmon.o hmac_md5.o libnetlink.o mstp.o \
    netif_utils.o packet.o worker.o config.o ubus.o \
    $DEPS_DIR/install/lib/libubox.a \
    $DEPS_DIR/install/lib/libubus.a \
    $DEPS_DIR/install/lib/libblobmsg_json.a \
    $LDFLAGS -ljson-c -lpthread \
    -o $OUT/ustp-fuzz

# Clean up object files
rm -f *.o

echo "Build completed successfully!"
echo "Fuzzer binary: $OUT/ustp-fuzz"
