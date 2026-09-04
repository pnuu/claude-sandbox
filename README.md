# claude-sandbox

Run [Claude Code](https://claude.com/claude-code) inside a rootless
[Podman](https://podman.io/) container, so that an agent editing your code
can reach exactly one project directory and nothing else on the machine.

The container gets two things from the host:

* a **persistent named volume** mounted at `/home/claude`, holding the Claude
  Code login, settings, skills, plugins, projects history and shell history,
  so you log in once and keep your setup across runs;
* **one work directory**, bind-mounted at `/workspace` — the directory you
  pass on the command line, or the current directory if you pass nothing.

Files the agent creates under the work directory appear on the host owned by
the user who started the container, not by root: the sandbox user is mapped
onto your host user with Podman's `--userns=keep-id`.

## Requirements

* Podman 4.3 or newer, running rootless (tested with 4.9 on Ubuntu).
* cgroups v2, for the memory/CPU/PID limits to take effect. Any recent
  systemd-based distribution qualifies.
* Network access for the build (Debian packages, NodeSource, npm) and for
  Claude Code itself at runtime.

## Quick start

```bash
git clone <this repository> && cd claude-sandbox

# Build the image (also happens automatically on first run).
./claude-sandbox.sh --build-only

# Start Claude Code on a project.
./claude-sandbox.sh ~/src/myproject

# Or on the current directory.
cd ~/src/myproject && /path/to/claude-sandbox.sh
```

The first run drops you into Claude Code's login flow. The credentials are
written to the persistent volume, so later runs start straight up.

It is convenient to put the script on your `PATH`:

```bash
ln -s "$PWD/claude-sandbox.sh" ~/.local/bin/claude-sandbox
```

## Usage

```
claude-sandbox.sh [options] [WORKDIR] [-- ARGS...]

  -s, --shell        Start an interactive bash shell instead of Claude Code.
  -b, --build        (Re)build the image before starting.
      --build-only   Build the image and exit.
      --no-network   Run without network access.
      --reset-home   Delete the persistent volume (logout + settings loss).
  -h, --help         Show help.
```

Anything after `--` is handed to the `claude` command line:

```bash
./claude-sandbox.sh ~/src/myproject -- --model opus
```

Use `--shell` when you want to poke at the sandbox itself — install an extra
package into the persistent home, inspect the volume, check a tool version.

## What is in the image

Debian bookworm, plus Node.js 22 (from NodeSource) and the
`@anthropic-ai/claude-code` npm package, plus the tools Claude Code and
ordinary development work tend to reach for: `git`, `git-lfs`,
`openssh-client`, `curl`, `wget`, `ripgrep`, `fd`, `jq`, `tree`, `less`,
`nano`, `vim-tiny`, `file`, `patch`, `diffutils`, archive tools, `make`,
`build-essential`, `pkg-config`, and Python 3 with `venv`, `pip` and `pipx`.

Claude Code is installed system-wide and its auto-updater is disabled
(`DISABLE_AUTOUPDATER=1`). Update it by rebuilding the image:

```bash
./claude-sandbox.sh --build --build-only
```

Extra tools you install at runtime with `npm install -g` or `pipx install`
land in the persistent home (`~/.npm-global`, `~/.local`) and survive
restarts; anything installed with `apt` does not, since the container is
started with `--rm` and the root filesystem is thrown away on exit.

## Resource limits

The limits live in clearly marked variables at the top of
`claude-sandbox.sh`, and each can also be overridden per run through an
environment variable:

| Variable            | Default | Environment override            |
| ------------------- | ------- | ------------------------------- |
| `MEMORY_LIMIT`      | `8g`    | `CLAUDE_SANDBOX_MEMORY`         |
| `MEMORY_SWAP_LIMIT` | `8g`    | `CLAUDE_SANDBOX_MEMORY_SWAP`    |
| `CPU_LIMIT`         | `4`     | `CLAUDE_SANDBOX_CPUS`           |
| `PIDS_LIMIT`        | `2048`  | `CLAUDE_SANDBOX_PIDS`           |
| `TMPFS_SIZE`        | `2g`    | `CLAUDE_SANDBOX_TMPFS`          |
| `SHM_SIZE`          | `256m`  | `CLAUDE_SANDBOX_SHM`            |

```bash
CLAUDE_SANDBOX_MEMORY=16g CLAUDE_SANDBOX_CPUS=8 ./claude-sandbox.sh ~/src/big
```

`MEMORY_SWAP_LIMIT` is the combined RAM+swap ceiling; keeping it equal to
`MEMORY_LIMIT` means the container cannot swap. `CPU_LIMIT` is a CPU-time
quota rather than a set of pinned cores, so `nproc` inside the container
still reports every host core — a parallel build may need `-j` set by hand
to stay near the quota.

## Security notes

What the sandbox does:

* **Rootless Podman.** The container runs entirely in your unprivileged user
  namespace; the "root" of the container is not root on the host.
* **Unprivileged user inside.** Processes run as `claude` (UID 1000), with
  `--cap-drop=ALL` and `--security-opt=no-new-privileges`, and the image is
  built with every setuid/setgid bit stripped and no `sudo` installed.
* **A single writable host path.** Only the directory you name is mounted.
  The rest of your home directory, your SSH keys and your other projects are
  not visible. The script refuses to mount `/` or your whole home directory.
* **Ephemeral root filesystem.** `--rm` plus a `nosuid,nodev` tmpfs `/tmp`.
* **Resource ceilings**, so a runaway process hits a limit instead of your
  desktop session.

What it does not do:

* **It does not restrict the network.** Claude Code needs to reach the
  Anthropic API, and no egress filtering is applied beyond that, so code run
  in the sandbox can talk to the internet. `--no-network` cuts the network
  off entirely, which also stops Claude Code from working — it is there for
  offline inspection of the environment.
* **It does not protect the work directory.** Everything under the directory
  you mount is fully writable, including a `.git` directory. Mount the
  narrowest directory that makes sense.
* **It does not hide secrets you hand it.** `ANTHROPIC_API_KEY` is forwarded
  into the container when it is set in your environment. `.env` files and
  credentials inside the work directory are readable by the sandbox.
* **It is not a security boundary against a determined kernel-level
  attacker.** It is a strong guardrail against mistakes and against ordinary
  malicious code, not a virtual machine.

Credentials in the persistent volume are stored unencrypted, as they are on a
normal Claude Code installation. Inspect or remove the volume with:

```bash
podman volume inspect claude-sandbox-home
./claude-sandbox.sh --reset-home
```

### Sharing your git identity

Commits made inside the sandbox use the container's default identity, since
`~/.gitconfig` is not visible. To reuse your host identity, mount it
read-only:

```bash
CLAUDE_SANDBOX_MOUNT_GITCONFIG=1 ./claude-sandbox.sh ~/src/myproject
```

The file is included into the sandbox's own git config rather than replacing
it, and is never writable from inside. Note that this exposes whatever your
`~/.gitconfig` contains, including any URL rewrites or credential helper
configuration — check it before turning this on. SSH keys are deliberately
never mounted; push from the host.

## Files

| File                | Purpose                                              |
| ------------------- | ---------------------------------------------------- |
| `Containerfile`     | Image definition.                                    |
| `entrypoint.sh`     | Prepares the persistent home, then execs the command. |
| `claude-sandbox.sh` | Host-side wrapper: limits, mounts, `podman run`.     |

## License

Apache License 2.0 — see [LICENSE](LICENSE).
