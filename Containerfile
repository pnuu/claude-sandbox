# SPDX-License-Identifier: Apache-2.0
#
# Sandbox image for running Claude Code in a rootless Podman container.
#
# The image intentionally contains no privilege-escalation helpers (no sudo,
# no setuid binaries beyond what the base image ships) and runs as an
# unprivileged user.  All persistent state lives in /home/claude, which the
# wrapper script mounts from a named volume.

FROM docker.io/library/debian:bookworm-slim

ARG NODE_MAJOR=22
ARG MICROMAMBA_VERSION=latest
ARG PYTHON_VERSION=3.14
ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Base tooling that Claude Code (and the code it works on) typically needs.
# Deliberately no C toolchain: everything native comes prebuilt from conda-forge,
# so a compiler would add some 190 MB for nothing.  `micromamba install
# compilers` brings one in at runtime if a source build is ever needed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        git \
        git-lfs \
        openssh-client \
        bash-completion \
        less \
        nano \
        vim-tiny \
        procps \
        psmisc \
        file \
        tree \
        unzip \
        zip \
        xz-utils \
        tar \
        gzip \
        bzip2 \
        ripgrep \
        fd-find \
        jq \
        diffutils \
        patch \
        make \
    && rm -rf /var/lib/apt/lists/*

# Node.js from NodeSource - Claude Code is distributed as an npm package.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# `fd` is called `fdfind` on Debian; give it its usual name.
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Claude Code itself, installed system-wide so that rebuilding the image
# (rather than writing into the persistent volume) is how it gets updated.
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# The unprivileged user is created before the Python environment so that the
# environment can be built with its ownership already correct; chowning it
# afterwards would copy all of its couple of gigabytes into a second layer.
RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home \
        --shell /bin/bash "${USERNAME}" \
    && mkdir -p /home/${USERNAME}/.claude \
                /home/${USERNAME}/.config \
                /home/${USERNAME}/.cache \
                /home/${USERNAME}/.local/bin \
                /home/${USERNAME}/.npm-global \
                /home/${USERNAME}/.mamba \
                /workspace \
    && chown -R "${USER_UID}:${USER_GID}" /home/${USERNAME} /workspace

# micromamba: the whole Python side of the image comes from conda-forge rather
# than from Debian, which is how the Pytroll stack is normally deployed and
# avoids Debian's externally-managed interpreter (PEP 668) entirely.
RUN curl -Ls "https://micro.mamba.pm/api/micromamba/linux-64/${MICROMAMBA_VERSION}" \
        | tar -xj -C /usr/local bin/micromamba \
    && micromamba --version

# Channel configuration for the user, not for the build below: this is the
# highest-precedence config file micromamba reads, so `micromamba install <pkg>`
# resolves against the same channel the image was built from without anyone
# having to pass -c.  The build itself stays hermetic with --no-rc.
RUN mkdir -p /etc/conda \
    && printf 'channels:\n  - conda-forge\nchannel_priority: strict\n' \
        > /etc/conda/.condarc

# The environment Claude Code works in.  It carries Satpy and Trollflow2 plus
# their test dependencies, so that both test suites run out of the box, and
# ruff for linting.  A checkout mounted at /workspace is layered on top with
# `pip install -e . --no-deps`, keeping the dependencies from the image and the
# code from the host.
#
# conda-forge has no notion of the projects' "tests" extras, so those are listed
# out here; keep them in sync with the `tests` extra of Satpy's pyproject.toml
# and the `test` extra of Trollflow2's.  Trollflow2 itself is not on conda-forge
# and follows below, from PyPI.
#
# astropy and geoviews are conda-forge metapackages that pull in a pile of
# recommended extras - between them the whole IPython/Jupyter/ipywidgets stack,
# datashader and geopandas, some 110 MB.  The importable packages the tests
# actually need are astropy-base and geoviews-core.
#
# geoviews carries a lower bound because its old noarch builds declare no upper
# bound on Python; without one the solver happily picks a 2019 release that does
# not import on any modern interpreter.
#
# Trollflow2, its runtime dependency posttroll and its test dependency
# pytroll-schedule have no conda-forge packages, so they come from PyPI into the
# same environment.  They are pure Python, which keeps this free of the usual
# conda/pip mixing hazards - everything compiled is still conda-forge's.
#
# This is one long layer on purpose: the package caches must be gone, and the
# environment owned by the unprivileged user, in the same layer that creates
# them, or they stay in the image no matter what a later step deletes.
#
# MAMBA_ROOT_PREFIX here is only the build's scratch space, and is removed with
# the caches it holds; the runtime one is set further down, on the persistent
# home volume.
ENV MAMBA_ROOT_PREFIX=/opt/mamba \
    CONDA_PREFIX=/opt/conda
RUN micromamba create -y -p "${CONDA_PREFIX}" -c conda-forge --no-rc \
        "python=${PYTHON_VERSION}" \
        pip \
        ruff \
        satpy \
        astropy-base \
        behave \
        bokeh \
        bottleneck \
        dask-image \
        defusedxml \
        ephem \
        fsspec \
        "geoviews-core>=1.15" \
        h5netcdf \
        h5py \
        imageio \
        netcdf4 \
        numba \
        pint-xarray \
        pyhdf \
        pytest \
        pytest-lazy-fixtures \
        python-eccodes \
        python-geotiepoints \
        rasterio \
        rioxarray \
        s3fs \
        skyfield \
    && "${CONDA_PREFIX}/bin/pip" install --no-cache-dir --root-user-action=ignore \
        trollflow2 \
        pytroll-schedule \
    && micromamba clean --all --yes --force-pkgs-dirs \
    && rm -rf "${MAMBA_ROOT_PREFIX}" /root/.mamba /root/.conda /root/.cache \
    && chown -R "${USER_UID}:${USER_GID}" "${CONDA_PREFIX}"

# Drop the setuid/setgid bits from everything in the image.  Nothing in this
# sandbox needs them, and the container also runs with --cap-drop=ALL and
# no-new-privileges, so they would be dead weight at best.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# The environment is owned by the unprivileged user, so `micromamba install
# <pkg>` works without any privilege: CONDA_PREFIX makes /opt/conda the implicit
# target, and /etc/conda/.condarc supplies the channel.  Such an install lasts
# for the life of the container - /opt/conda is part of the image, not of a
# volume - so the root prefix is put on the persistent home instead.  That keeps
# the downloaded packages across sessions, which makes repeating an install
# cheap, and lets `micromamba create -n <name>` build environments that survive.
USER ${USERNAME}
ENV MAMBA_ROOT_PREFIX=/home/${USERNAME}/.mamba \
    HOME=/home/${USERNAME} \
    NPM_CONFIG_PREFIX=/home/${USERNAME}/.npm-global \
    PATH=/home/${USERNAME}/.npm-global/bin:/home/${USERNAME}/.local/bin:/opt/conda/bin:/usr/local/bin:/usr/bin:/bin \
    DISABLE_AUTOUPDATER=1 \
    CONDA_DEFAULT_ENV=/opt/conda \
    GDAL_DATA=/opt/conda/share/gdal \
    PROJ_DATA=/opt/conda/share/proj \
    SSL_CERT_FILE=/opt/conda/ssl/cacert.pem

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
