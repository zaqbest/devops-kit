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
| 2 | **Swap** | Auto-size based on RAM (≤2G → RAM×2, 2–8G → RAM, >8G → RAM/2, capped at `SWAP_MAX_GB`). Persists in `/etc/fstab`, skipped in containers |
| 3 | **Timezone + Locale** | `Asia/Shanghai` (UTC+8) + `en_US.UTF-8` |
| 4 | **Firewall off** | Stops/disables `ufw`, `firewalld`, `nftables`; flushes `iptables`/`ip6tables`; sets SELinux to permissive |
| 5 | **High-concurrency tuning** | `/etc/sysctl.d/99-devops-bootstrap.conf` + `/etc/security/limits.d/99-devops-bootstrap.conf` + systemd `DefaultLimit*` + PAM `pam_limits` |
| 6 | **SSH keys** | Appends the keys defined in `SSH_PUBLIC_KEYS` array to `/root/.ssh/authorized_keys` (idempotent, dedup by key body), enables `PubkeyAuthentication yes` |

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
| `-y`, `--yes` | Non-interactive; assume "yes" to prompts |
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
| `tools/git/git-pull-all.sh` | `git pull` in every immediate sub-repo |
| `tools/git/git-fetch-all.sh` | `git fetch --all` in every immediate sub-repo |
| `tools/git/git-diff.sh` | Show unstaged/staged/unpushed changes across repos |

`bin/git-pull-all.sh`, `bin/git-fetch-all.sh`, `bin/git-diff-sh` are shortcut
copies for adding `bin/` to your `$PATH`.

Usage:

```bash
cd ~/workspace         # a directory containing many Git repos
bash ~/devops-kit/tools/git/git-pull-all.sh
bash ~/devops-kit/tools/git/git-fetch-all.sh
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