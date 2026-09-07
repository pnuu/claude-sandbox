#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# claude-sandbox.sh - run Claude Code inside a rootless Podman container.
#
# The container gets exactly two things from the host: a persistent named
# volume for Claude Code's own state (login credentials, settings, skills,
# history) and one work directory of your choosing.  Everything else - the
# rest of your home directory, your SSH keys, your other projects - stays
# out of reach.

set -euo pipefail

# --------------------------------------------------------------------------
# Tunables.  Each can also be overridden through the environment variable
# shown in the default expression, e.g.
#   CLAUDE_SANDBOX_MEMORY=16g ./claude-sandbox.sh ~/src/myproject
# --------------------------------------------------------------------------

# Image and persistent-volume names.
IMAGE_NAME="${CLAUDE_SANDBOX_IMAGE:-localhost/claude-sandbox:latest}"
VOLUME_NAME="${CLAUDE_SANDBOX_VOLUME:-claude-sandbox-home}"

# Resource limits.  Raise or lower these to taste; they are the only thing
# standing between a runaway build and your desktop session.
MEMORY_LIMIT="${CLAUDE_SANDBOX_MEMORY:-8g}"        # hard RAM limit
MEMORY_SWAP_LIMIT="${CLAUDE_SANDBOX_MEMORY_SWAP:-8g}"  # RAM+swap; equal to
                                                   # MEMORY_LIMIT means "no swap"
CPU_LIMIT="${CLAUDE_SANDBOX_CPUS:-4}"              # CPU cores (fractions ok)
PIDS_LIMIT="${CLAUDE_SANDBOX_PIDS:-2048}"          # fork-bomb guard
TMPFS_SIZE="${CLAUDE_SANDBOX_TMPFS:-2g}"           # size of the in-memory /tmp
SHM_SIZE="${CLAUDE_SANDBOX_SHM:-256m}"             # /dev/shm

# UID/GID of the unprivileged user inside the image.  Must match the
# USER_UID/USER_GID build arguments in the Containerfile.
CONTAINER_UID="${CLAUDE_SANDBOX_UID:-1000}"
CONTAINER_GID="${CLAUDE_SANDBOX_GID:-1000}"

# Set to 1 to bind-mount ~/.gitconfig read-only so commits made in the
# sandbox carry your usual name and e-mail address.
MOUNT_GITCONFIG="${CLAUDE_SANDBOX_MOUNT_GITCONFIG:-0}"

# --------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROG="$(basename -- "${BASH_SOURCE[0]}")"

usage() {
    cat <<EOF
Usage: ${PROG} [options] [WORKDIR] [-- ARGS...]

Run Claude Code in a Podman sandbox.  WORKDIR (default: the current
directory) is mounted at /workspace inside the container and is the only
host path the container can write to besides its own persistent volume.

Options:
  -s, --shell        Start an interactive bash shell instead of Claude Code.
  -b, --build        (Re)build the image before starting.
      --build-only   Build the image and exit.
      --no-network   Run without network access (offline inspection only;
                     Claude Code itself needs the network to work).
      --reset-home   Delete the persistent volume (logout + settings loss)
                     and exit.
  -h, --help         Show this help.

Everything after \`--\` is passed straight to the \`claude\` command line, e.g.
  ${PROG} ~/src/project -- --model opus

Environment overrides: CLAUDE_SANDBOX_MEMORY, CLAUDE_SANDBOX_CPUS,
CLAUDE_SANDBOX_PIDS, CLAUDE_SANDBOX_IMAGE, CLAUDE_SANDBOX_VOLUME,
CLAUDE_SANDBOX_MOUNT_GITCONFIG, CLAUDE_SANDBOX_SSHD.
EOF
}

die() { printf '%s: %s\n' "${PROG}" "$*" >&2; exit 1; }

build_image() {
    printf '%s: building %s ...\n' "${PROG}" "${IMAGE_NAME}" >&2
    podman build \
        --build-arg "USER_UID=${CONTAINER_UID}" \
        --build-arg "USER_GID=${CONTAINER_GID}" \
        -t "${IMAGE_NAME}" \
        -f "${SCRIPT_DIR}/Containerfile" \
        "${SCRIPT_DIR}"
}

WORKDIR=""
DO_BUILD=0
BUILD_ONLY=0
USE_SHELL=0
NO_NETWORK=0
RESET_HOME=0
PASSTHROUGH=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage; exit 0 ;;
        -s|--shell)    USE_SHELL=1 ;;
        -b|--build)    DO_BUILD=1 ;;
        --build-only)  DO_BUILD=1; BUILD_ONLY=1 ;;
        --no-network)  NO_NETWORK=1 ;;
        --reset-home)  RESET_HOME=1 ;;
        --)            shift; PASSTHROUGH=("$@"); break ;;
        -*)            die "unknown option: $1 (try --help)" ;;
        *)
            [ -z "${WORKDIR}" ] || die "more than one work directory given: $1"
            WORKDIR="$1"
            ;;
    esac
    shift
done

command -v podman >/dev/null 2>&1 || die "podman is not installed"

if [ "${RESET_HOME}" -eq 1 ]; then
    printf 'This deletes the volume %s, including the Claude Code login.\n' \
        "${VOLUME_NAME}" >&2
    read -r -p 'Type "yes" to continue: ' reply
    [ "${reply}" = "yes" ] || die "aborted"
    podman volume rm "${VOLUME_NAME}"
    exit 0
fi

if [ "${DO_BUILD}" -eq 1 ] || ! podman image exists "${IMAGE_NAME}"; then
    build_image
fi
if [ "${BUILD_ONLY}" -eq 1 ]; then
    exit 0
fi

WORKDIR="${WORKDIR:-$PWD}"
[ -d "${WORKDIR}" ] || die "work directory does not exist: ${WORKDIR}"
WORKDIR="$(cd -- "${WORKDIR}" && pwd -P)"

case "${WORKDIR}" in
    /|"${HOME}")
        die "refusing to mount ${WORKDIR}; point me at a project directory" ;;
esac

# Create the persistent volume up front so its first-use contents are copied
# from the image (correct ownership for the sandbox user).
podman volume exists "${VOLUME_NAME}" || podman volume create "${VOLUME_NAME}" >/dev/null

# Relabel bind mounts only where SELinux is actually in play.
MOUNT_SUFFIX=""
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    MOUNT_SUFFIX=":Z"
fi

RUN_ARGS=(
    --rm
    --interactive --tty
    --hostname claude-sandbox

    # Map the host user onto the sandbox user, so files created under
    # /workspace land on the host owned by whoever started the container.
    "--userns=keep-id:uid=${CONTAINER_UID},gid=${CONTAINER_GID}"
    "--user=${CONTAINER_UID}:${CONTAINER_GID}"

    # Hardening: no capabilities, no way to gain privileges, no writable
    # on-disk scratch space outside the two mounts.
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --tmpfs "/tmp:rw,nosuid,nodev,exec,size=${TMPFS_SIZE}"
    "--shm-size=${SHM_SIZE}"

    # Resource limits.
    "--memory=${MEMORY_LIMIT}"
    "--memory-swap=${MEMORY_SWAP_LIMIT}"
    "--cpus=${CPU_LIMIT}"
    "--pids-limit=${PIDS_LIMIT}"

    # Persistent state and the work directory.
    -v "${VOLUME_NAME}:/home/claude"
    -v "${WORKDIR}:/workspace${MOUNT_SUFFIX}"
    -w /workspace

    -e "TERM=${TERM:-xterm-256color}"
)

if [ -n "${COLORTERM:-}" ]; then
    RUN_ARGS+=(-e "COLORTERM=${COLORTERM}")
fi

# Only forwarded when you actually use an API key; the usual login flow keeps
# its credentials inside the persistent volume instead.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    RUN_ARGS+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
fi

# The entrypoint starts an SSH server on the container's loopback interface;
# forward the switch that turns it off.
if [ -n "${CLAUDE_SANDBOX_SSHD:-}" ]; then
    RUN_ARGS+=(-e "CLAUDE_SANDBOX_SSHD=${CLAUDE_SANDBOX_SSHD}")
fi

if [ "${NO_NETWORK}" -eq 1 ]; then
    RUN_ARGS+=(--network=none)
fi

if [ "${MOUNT_GITCONFIG}" = "1" ] && [ -f "${HOME}/.gitconfig" ]; then
    RUN_ARGS+=(-v "${HOME}/.gitconfig:/home/claude/.gitconfig.host:ro${MOUNT_SUFFIX}"
               -e "CLAUDE_SANDBOX_HOST_GITCONFIG=/home/claude/.gitconfig.host")
fi

if [ "${USE_SHELL}" -eq 1 ]; then
    CMD=(bash)
else
    CMD=(claude "${PASSTHROUGH[@]}")
fi

exec podman run "${RUN_ARGS[@]}" "${IMAGE_NAME}" "${CMD[@]}"
