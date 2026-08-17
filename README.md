# devops-kit

A collection of self-contained shell scripts for common DevOps / SRE tasks:
VPS bootstrap, TLS certificates, Elasticsearch backups, and Git multi-repo
helpers.

## 🚀 快速开始 / Quick Start

在一台**刚装好的 Linux VPS** 上以 `root` 身份执行一条命令，即可完成 OS 探测、
Swap、时区/Locale、防火墙、内核 & ulimit 调优、SSH 公钥注入等全部初始化。

```bash
# GitHub 主干（默认，交互式）
bash <(curl -fsSL https://bootstrap.zaqbest.com)

# 全自动（不询问，适合脚本 / cloud-init user-data）
bash <(curl -fsSL https://bootstrap.zaqbest.com) --yes

# 演练模式（打印将要执行的操作，不做任何更改）
bash <(curl -fsSL https://bootstrap.zaqbest.com) --dry-run
```

> **注入自己的 SSH 公钥**：脚本顶部有 `SSH_PUBLIC_KEYS=(...)` 数组，请 fork 本仓库
> 并修改数组内容后再运行，或用 `curl | sed | bash` 的方式在管道中替换公钥。

Cloud-init `user-data` 示例：

```yaml
#cloud-config
runcmd:
  - bash <(curl -fsSL https://bootstrap.zaqbest.com) --yes
```

## 📁 项目结构

```
devops-kit/
├── initialization/          # VPS post-install bootstrap
│   └── bootstrap.sh         # ★ single self-contained init script
├── certificates/            # TLS certificate utilities (self-signed CA, JDK/system trust)
├── tools/
│   ├── elasticsearch/       # Elasticsearch export/import via elasticdump
│   └── git/                 # Multi-repo Git helpers (pull/fetch/diff)
└── bin/                     # Convenience symlinks/copies of frequently used scripts
```


## 1. VPS Bootstrap — `initialization/bootstrap.sh`

A **single, self-contained** post-install initialization script for freshly
provisioned Linux servers. No external dependencies — just copy the one file
and run it.

### What it does

| # | Task | Detail |
|---|------|--------|
| 1 | **Detect OS** | Family (debian / rhel / alpine), version, arch (amd64/arm64/…), package manager, init system |
| 2 | **Essential packages** | `curl`, `wget`, `git`, `vim`, `tar`, `unzip`, `ca-certificates` + distro-specific extras (`gnupg`, `dnsutils`/`bind-utils`, `net-tools`, `htop`, …) |
| 3 | **Swap** | Auto-size based on RAM (≤2G → RAM×2, 2–8G → RAM, >8G → RAM/2, capped at `SWAP_MAX_GB`). Persists in `/etc/fstab`, skipped in containers |
| 4 | **Timezone + Locale** | `Asia/Shanghai` (UTC+8) + `en_US.UTF-8` |
| 5 | **Firewall off** | Stops/disables `ufw`, `firewalld`, `nftables`; flushes `iptables`/`ip6tables`; sets SELinux to permissive |
| 6 | **High-concurrency tuning** | `/etc/sysctl.d/99-devops-bootstrap.conf` + `/etc/security/limits.d/99-devops-bootstrap.conf` + systemd `DefaultLimit*` + PAM `pam_limits` |
| 7 | **SSH keys** | Appends the keys defined in `SSH_PUBLIC_KEYS` array to `/root/.ssh/authorized_keys` (idempotent, dedup by key body), enables `PubkeyAuthentication yes` |
| 8 | **Docker _(optional)_** | Asks interactively (**default: NO**); installs Docker CE via [`https://get.docker.com`](https://get.docker.com) (or `apk add docker` on Alpine). Non-interactive mode skips unless `--with-docker` is passed |

### Usage

```bash
# 1) Copy the script to the target machine
scp initialization/bootstrap.sh root@vps:/tmp/

# 2a) Interactive (asks for confirmation)
ssh root@vps 'bash /tmp/bootstrap.sh'

# 2b) Non-interactive (auto)
ssh root@vps 'bash /tmp/bootstrap.sh --yes'

# 2c) Preview only, no changes
ssh root@vps 'bash /tmp/bootstrap.sh --dry-run'

# Or one-liner via curl (host the file on your own server / gist / repo)
ssh root@vps 'curl -fsSL https://your.host/bootstrap.sh | bash -s -- --yes'
```

### Configuration (top of the file)

```bash
SSH_PUBLIC_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAA...key1"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAA...key2"
)
TIMEZONE="Asia/Shanghai"
LOCALE="en_US.UTF-8"
SWAP_MAX_GB=8
LOG_FILE="/var/log/devops-bootstrap.log"
```

Edit the array at the top of `initialization/bootstrap.sh` to inject your own
SSH public keys before deployment.

### CLI flags

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Non-interactive; assume "yes" to prompts (Docker still skipped unless `--with-docker`) |
| `--with-docker` | Install Docker (skip the confirmation prompt) |
| `--no-docker` | Never install Docker (skip the confirmation prompt) |
| `-n`, `--dry-run` | Print commands but don't modify anything |
| `-h`, `--help` | Show the header comment (usage & feature list) |

### Compatibility

Debian · Ubuntu · CentOS · RHEL · Rocky · AlmaLinux · Fedora · Alpine
(x86_64 / arm64 / armv7)

### Safety features

- Root check + `set -euo pipefail` + `ERR` trap with line number
- Idempotent (swap/keys/sshd changes check current state first)
- `sshd -t` validation before reloading sshd (won't lock you out)
- Colored terminal output + log file at `/var/log/devops-bootstrap.log`
- All modifications go through a `run()` wrapper so `--dry-run` is complete

---

## 2. TLS Certificates — `certificates/`

Utilities for managing self-signed TLS certificates and installing them into
system trust stores or JDKs.

```
certificates/
├── self-signed/
│   ├── generate-ca.sh          # Create your own private CA
│   ├── generate-domain.sh      # Issue a domain cert signed by that CA
│   ├── generate-app.sh         # Issue an application cert
│   └── openssl.cnf.template
├── check-expiry.sh             # Warn about upcoming certificate expiry
├── install-to-system.sh        # Trust cert at OS level (Ubuntu/Debian/RHEL/macOS)
└── install-to-jdk.sh           # Import cert into a specific JDK's cacerts
```

Example workflow:

```bash
# 1. Bootstrap a CA once
bash certificates/self-signed/generate-ca.sh

# 2. Issue a cert for a domain
bash certificates/self-signed/generate-domain.sh localtest.zaqbest.com

# 3. Trust the CA on this machine
sudo bash certificates/install-to-system.sh certificates/self-signed/ca/certs/ca.crt

# 4. Or import into a JDK
bash certificates/install-to-jdk.sh /path/to/jdk certificates/self-signed/ca/certs/ca.crt
```

---

## 3. Elasticsearch backup — `tools/elasticsearch/`

Export/import Elasticsearch indices via
[elasticdump](https://github.com/elasticsearch-dump/elasticsearch-dump).
See [`tools/elasticsearch/README.md`](tools/elasticsearch/README.md) for full
details.

```bash
# Export
bash tools/elasticsearch/es-export.sh <src_url> <index> <backup_dir>

# Import (with optional --shards / --replicas patching)
bash tools/elasticsearch/es-import.sh <dst_url> <index> <backup_dir> [--shards N] [--replicas N]
```

Symlinks are provided in `bin/` for convenience: `bin/es-export.sh`, `bin/es-import.sh`.

---

## 4. Git multi-repo helpers — `tools/git/`

Batch operations across multiple Git repositories under a parent folder.

| Script | Purpose |
|---|---|
| `tools/git/git-sync-all.sh` | Fetch remotes + FF all branches + pull current, across every immediate sub-repo (two subcommands: `fetch`, `pull`) |
| `tools/git/git-diff.sh` | Show unstaged/staged/unpushed changes across repos |

`bin/git-sync-all.sh`, `bin/git-diff-sh` are shortcut copies for adding `bin/`
to your `$PATH`.

### `git-sync-all.sh`

Two subcommands. `fetch` is the default when none is given.

**`fetch` (default)** — for every local branch of every repo, in this order:

1. `git fetch --all --prune --tags` (updates remote-tracking refs only)
2. For each **non-current** local branch with an upstream that can fast-forward:
   `git fetch <remote> <rbranch>:<lbranch>` — updates the local branch without
   switching to it.
3. On the **current** branch: `git pull --ff-only`.

Diverged / no-upstream branches are reported and skipped.

**`pull`** — plain `git pull` on the current branch of each repo. Leaves all
other local branches untouched.

**Tag handling** is temperate by default: `--tags` is passed to fetch, but
local tags are NOT force-overwritten. If the remote force-moved a tag you
already have locally, git will reject the fetch with a _"would clobber existing
tag"_ error. To resolve:

| Flag | Effect |
|---|---|
| `--force-tags` | Mirror remote tags exactly: adds `--prune-tags` + `--force`, so force-moved remote tags overwrite the local ones, and local tags no longer on the remote are deleted. Only touches local refs — `fetch` never mutates the remote. |
| `--no-tags` | Skip tag sync entirely (still fetches branches). |
| `--prune-tags` | Deprecated alias for `--force-tags`, kept for compat. |

Other `fetch` flags:

| Flag | Effect |
|---|---|
| `--fetch-only` | Do not pull the current branch (steps 1 + 2 only). |
| `--remote <name>` | Restrict to a single remote instead of `--all`. |

`pull` flags:

| Flag | Effect |
|---|---|
| `--ff-only` | Refuse non-fast-forward merges (safer). |
| `--rebase` | Rebase local commits on top of the remote instead of merging. |

Directory resolution: if the argument is itself a git repo it's processed
directly; otherwise one level of subdirectories is scanned and every
subdirectory that is a git repo is processed.

Usage:

```bash
cd ~/workspace         # a directory containing many Git repos

# Default: fetch all remotes, FF every branch, and pull the current branch
bash ~/devops-kit/tools/git/git-sync-all.sh

# Same, but leave the current branch alone
bash ~/devops-kit/tools/git/git-sync-all.sh --fetch-only

# When a repo has tags that were force-moved on the remote (e.g. CI-managed
# `last-released/*` tags), rerun with --force-tags to mirror remote tags:
bash ~/devops-kit/tools/git/git-sync-all.sh fetch --force-tags

# Or skip tags entirely
bash ~/devops-kit/tools/git/git-sync-all.sh fetch --no-tags

# Restrict to a single remote
bash ~/devops-kit/tools/git/git-sync-all.sh fetch --remote origin

# Plain `git pull` on the current branch only (does not touch other branches)
bash ~/devops-kit/tools/git/git-sync-all.sh pull --ff-only

bash ~/devops-kit/tools/git/git-diff.sh
```

---

## Design philosophy

- **Self-contained** — every script can be copied to a target host and run
  without pulling in the rest of the kit (`bootstrap.sh` is a strict example
  of this).
- **Idempotent** — running a script twice must not break anything and should
  detect existing state.
- **Dry-run** — mutating scripts (`bootstrap.sh`) support `--dry-run` for
  auditing.
- **POSIX-ish bash** — targets bash 4+; avoids exotic dependencies. Uses only
  tools present in a minimal server install (or installs them via the local
  package manager).
- **Safety first** — `set -euo pipefail`, `ERR` traps, config validation
  before service reloads (e.g. `sshd -t`), backups of critical files before
  edits.

---

## License

Internal DevOps tooling — use freely inside your organization.