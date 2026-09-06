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

exec "$@"
