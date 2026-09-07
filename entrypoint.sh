#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Container entrypoint: make sure the persistent home has the directories
# Claude Code expects, then hand over to the requested command.
set -euo pipefail

mkdir -p "${HOME}/.claude" \
         "${HOME}/.config" \
         "${HOME}/.cache" \
         "${HOME}/.local/bin" \
         "${HOME}/.npm-global" \
         "${MAMBA_ROOT_PREFIX:-${HOME}/.mamba}"

# Pull in the host's git identity when the wrapper was asked to share it.
# It is included rather than used directly as the global config, so that the
# file itself can stay read-only.
if [ -n "${CLAUDE_SANDBOX_HOST_GITCONFIG:-}" ] \
   && [ -r "${CLAUDE_SANDBOX_HOST_GITCONFIG}" ]; then
    git config --global --get-all include.path 2>/dev/null \
        | grep -qxF "${CLAUDE_SANDBOX_HOST_GITCONFIG}" \
        || git config --global --add include.path "${CLAUDE_SANDBOX_HOST_GITCONFIG}"
fi

# The work directory is bind-mounted from the host.  Ownership matches the
# host user thanks to --userns=keep-id, but git is still picky about
# repositories it did not see created, so mark this one as safe.
if [ -d /workspace ]; then
    git config --global --get-all safe.directory 2>/dev/null \
        | grep -qx '/workspace' \
        || git config --global --add safe.directory /workspace
fi

# SSH to the container itself.  The keys live on the persistent home, so they
# are made once and then reused: a host key for the sandbox sshd, and a
# passphraseless key pair which is authorized for the sandbox user, so that
# `ssh localhost` - and anything driving SSH, such as paramiko or scp - gets in
# without a prompt.  The image supplies the matching client configuration, so
# neither the port nor the key has to be named.
setup_ssh_keys() {
    local dir="${HOME}/.ssh"
    local key="${HOME}/.ssh/id_ed25519"
    local host_key="${HOME}/.ssh/ssh_host_ed25519_key"
    local authorized="${HOME}/.ssh/authorized_keys"

    mkdir -p "${dir}"
    chmod 700 "${dir}"

    [ -f "${host_key}" ] \
        || ssh-keygen -q -t ed25519 -N '' -f "${host_key}" \
            -C "claude-sandbox host key"
    [ -f "${key}" ] \
        || ssh-keygen -q -t ed25519 -N '' -f "${key}" \
            -C "$(id -un)@claude-sandbox"

    touch "${authorized}"
    chmod 600 "${authorized}"
    if ! grep -qF -- "$(cut -d' ' -f2 "${key}.pub")" "${authorized}"; then
        cat "${key}.pub" >> "${authorized}"
    fi
}

# The daemon is left unsupervised on purpose: the container lives for the
# command below and ends with it, so a server that dies takes nothing with it.
# It runs as the sandbox user on port 2222, and logs to the persistent home
# because there is no syslog to write to.  A failure to start is reported but
# not fatal - the sandbox is still perfectly usable without it.  Set
# CLAUDE_SANDBOX_SSHD=0 to leave it out altogether.
if [ "${CLAUDE_SANDBOX_SSHD:-1}" != "0" ] && [ -x /usr/sbin/sshd ]; then
    { setup_ssh_keys \
      && /usr/sbin/sshd -f /etc/ssh/sshd_config.sandbox \
           -E "${HOME}/.ssh/sshd.log"; } \
        || printf 'entrypoint: sshd did not start; see %s\n' \
               "${HOME}/.ssh/sshd.log" >&2
fi

exec "$@"
