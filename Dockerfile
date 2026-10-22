FROM debian:bookworm-slim AS base

# Layer 1: common OS deps (very stable, cached across all builds)
RUN apt-get update && apt-get install --no-install-recommends -y \
      build-essential \
      curl \
      git \
      ca-certificates \
      sudo \
  && rm -rf /var/lib/apt/lists/*

# Layer 2: rpi-image-gen, pinned to a commit for reproducible builds.
# master changes its layout/hook format often; an unpinned clone means the
# next Docker rebuild may silently pick up an incompatible version.
# a67e556 = master on 2026-10-21, the version the current images build with.
# Override with: docker build --build-arg RPI_IMAGE_GEN_REF=<commit|tag>
ARG RPI_IMAGE_GEN_REF=a67e556612a1f902245b2dc1b21c476f570e16b5
RUN git init -q rpi-image-gen \
  && git -C rpi-image-gen remote add origin https://github.com/raspberrypi/rpi-image-gen.git \
  && git -C rpi-image-gen fetch -q --depth 1 origin "$RPI_IMAGE_GEN_REF" \
  && git -C rpi-image-gen checkout -q FETCH_HEAD \
  && git -C rpi-image-gen log -1 --format='rpi-image-gen %H (%cd)'

# Layer 3: arch-specific deps (changes when TARGETARCH changes)
ARG TARGETARCH
RUN echo "Building for architecture: ${TARGETARCH}"
RUN /bin/bash -c '\
  case "${TARGETARCH}" in \
    arm64) echo "Building for arm64" && \
      apt-get update && \
      rpi-image-gen/install_deps.sh ;; \
    amd64) echo "Try to Build for amd64. \
      As of Apr 2025 rpi-image-gen install_deps exits if arm arch is not detected. \
      Override binfmt_misc_required flag and install known amd64 deps that are not \
      provided in the depends file" && \
      if cat /proc/filesystems | grep -q binfmt_misc; then \
        echo "binfmt_misc is supported" ; \
      else \
        echo "binfmt_misc is not supported. Install binfmt-support on your host machine" ; \
        exit 1 ; \
      fi && \
      apt-get update && \
      apt-get install --no-install-recommends -y \
        qemu-user-static \
        dirmngr \
        slirp4netns \
        quilt \
        parted \
        debootstrap \
        zerofree \
        libcap2-bin \
        libarchive-tools \
        xxd \
        file \
        kmod \
        bc \
        pigz \
        arch-test && \
      rpi-image-gen/install_deps.sh ;; \
    *) echo "Architecture ${TARGETARCH} is not arm64 or amd64. Skipping package installation." ;; \
  esac' \
  && rm -rf /var/lib/apt/lists/*

# Layer 5: user setup (stable)
# The build user password is "imagegen" (build.sh uses it to discard the
# cached filesystem, which is owned by root).
ENV USER=imagegen
RUN useradd -u 4000 -ms /bin/bash "$USER" && echo "${USER}:${USER}" | chpasswd && adduser ${USER} sudo
USER ${USER}
WORKDIR /home/${USER}

# The work directory is mounted from a docker volume (see docker-compose.yml).
# Pre-creating it here makes the fresh volume inherit this ownership, so the
# build user can write the rpi-image-gen workroot and the APT cache.
RUN mkdir -p /home/${USER}/work && chown ${USER}:${USER} /home/${USER}/work

RUN /bin/bash -c 'cp -r /rpi-image-gen ~/'
