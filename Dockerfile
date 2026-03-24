FROM debian:bookworm AS base

RUN apt-get update && apt-get install --no-install-recommends -y \
      build-essential \
      curl \
      git \
      ca-certificates \
      sudo \
      gpg \
      gpg-agent \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --branch master --depth 1 https://github.com/raspberrypi/rpi-image-gen.git

ARG TARGETARCH
RUN echo "Building for architecture: ${TARGETARCH}"
# Example: Install different packages based on architecture
RUN /bin/bash -c '\
  case "${TARGETARCH}" in \
    arm64) echo "Building for arm64" && \
      apt-get update && \
      rpi-image-gen/install_deps.sh ;; \
    amd64) echo "Try to Build for amd64. \
      As of Apr 2025 rpi-image-gen install_deps exits if arm arch is not detected. \
      Override binfmt_misc_required flag and install known amd64 deps that are not \
      provided in the depends file" && \
      sed -i "s|\"\${binfmt_misc_required}\" == \"1\"|! -z \"\"|g" rpi-image-gen/scripts/dependencies_check && \
      if cat /proc/filesystems | grep -q binfmt_misc; then \
        echo \"binfmt_misc is supported\" ; \
      else \
        echo \"binfmt_misc is not supported. Install binfmt-support on your host machine\" ; \
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
    *) echo "Architecture $ARCH is not arm64 or amd64. Skipping package installation." ;; \
  esac'

ENV USER imagegen
RUN useradd -u 4000 -ms /bin/bash "$USER" && echo "${USER}:${USER}" | chpasswd && adduser ${USER} sudo # only add to sudo if build scripts require it
USER ${USER}
WORKDIR /home/${USER}

RUN /bin/bash -c 'cp -r /rpi-image-gen ~/'

# Patch IDP v2 schema to include pi3 (exists as a device layer but was omitted from schema enum)
RUN python3 -c "\
import json; \
path = 'rpi-image-gen/layer/base/schemas/idp/v2/schema.json'; \
d = json.load(open(path)); \
enum = d['properties']['IGmeta']['properties']['IGconf_device_class']['enum']; \
'pi3' not in enum and enum.insert(0, 'pi3'); \
open(path, 'w').write(json.dumps(d, indent=4)) \
"