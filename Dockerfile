FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        autoconf automake libtool pkg-config \
        build-essential clang \
        libpcre2-dev libxml2-dev \
        curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

# Populate the jsmn submodule (it is empty in shallow clones)
RUN curl -fsSL https://raw.githubusercontent.com/zserge/jsmn/master/jsmn.h \
        -o /src/jsmn/jsmn.h

# Generate the configure script via autoreconf
RUN autoreconf --install -I m4

# Touch autotools timestamps to avoid "aclocal-1.xx not found" errors
RUN touch configure.ac Makefile.am aclocal.m4 configure \
         $(find . -name "Makefile.in") 2>/dev/null || true

# Configure and build with clang; -gdwarf-4 avoids DWARF 5 linker issues
RUN CC=clang \
    CFLAGS="-gdwarf-4 -O1 -g" \
    ./configure \
        --disable-bindings \
        --disable-python \
        --enable-release \
        --disable-maintainer-mode \
        --disable-shared \
        --enable-static && \
    make -j"$(nproc)" -C src && \
    make -j"$(nproc)" -C examples llvmfuzz_standalone

############################
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libpcre2-8-0 libxml2 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/examples/llvmfuzz_standalone /llvmfuzz_standalone
COPY --from=builder /src/test/test-data /corpus

ENTRYPOINT ["/llvmfuzz_standalone"]
