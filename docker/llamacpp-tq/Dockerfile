ARG CUDA_VERSION=12.6.0

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS builder

# CUDA_ARCH=89 targets Ada Lovelace (RTX 4080/4090).
# Pass --build-arg CUDA_ARCH=86 for Ampere (RTX 3080/3090).
ARG CUDA_ARCH=89

RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake ninja-build build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 \
    https://github.com/AtomicBot-ai/atomic-llama-cpp-turboquant .

# libcuda.so.1 is injected by nvidia-container-runtime at runtime, not present
# in the build image. Symlink the CUDA toolkit stub into a standard lib path
# so the linker can resolve transitive references during the build.
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so.1 && \
    ldconfig

RUN cmake -B build -G Ninja \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --target llama-server -j"$(nproc)"

FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl libgomp1 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=builder /build/build/bin/*.so* /usr/local/lib/
RUN ldconfig

ENTRYPOINT ["llama-server"]
