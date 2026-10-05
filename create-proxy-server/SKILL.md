---
name: create-proxy-server
description: >-
  Installs an authenticated Squid HTTP forward proxy on a Claroty SRA lab host.
  Resolves SSH via sshTermCmd / shai-access-sra-ssh, opens nft port 3128, runs
  Squid in Docker with Basic auth shai/1234!, and verifies CONNECT. Use when the
  user asks for create-proxy-server, to create/set up/install a proxy server on
  an IP, or to put Squid/HTTP proxy on an SRA site or SAC.
disable-model-invocation: true
---

# create-proxy-server

Install a lab HTTP forward proxy on a given SRA host IP.

## Defaults (do not change unless the user overrides)

| Item | Value |
|------|-------|
| Proxy type | Squid (`ubuntu/squid:latest`) |
| Listen port | **3128** |
| Auth user | `shai` |
| Auth password | `1234!` |
| Container name | `squid-proxy` |
| Config dir | `/opt/squid/config` |
| Helper script | `$HOME/proxy.sh` on the remote user (`--run` / `--stop` / `--status`) |

## Preconditions

1. **Read and follow** the local `shai-access-sra-ssh` skill for SSH.
2. User must give a target **IP** (or hostname). Ask once if missing.

## Workflow

```
- [ ] 1. Resolve SSH (sshTermCmd -q <IP>)
- [ ] 2. Probe host (docker, existing proxy)
- [ ] 3. Run install script as root
- [ ] 4. Verify CONNECT 200 / bad auth 407
- [ ] 5. Report connection details
```

### Step 1: Resolve SSH

```bash
sshTermCmd -q <IP>
```

Build SSH from the printed fields (password → `sshpass`; key → `dev` + `master_rsa_key`). Prefer piping scripts over `sudo bash -s` when `scp` is flaky.

SSH options that avoid agent key spam:

```bash
-o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o IdentityAgent=none
```

For password auth also: `-o PreferredAuthentications=password -o PubkeyAuthentication=no`.

### Step 2: Probe

Confirm Docker works and note whether `squid-proxy` / port `3128` already exist. Reinstall is OK (script removes old `squid-proxy` / `http-proxy`).

Detect remote login user home (`/home/shai.m` or `/home/dev`) for `proxy.sh`.

### Step 3: Install

Pipe the skill script as root:

```bash
# password example
sshpass -p '<password>' ssh <ssh-opts> <user>@<IP> 'sudo bash -s' \
  < ~/.cursor/skills/create-proxy-server/scripts/install_squid_proxy.sh

# key example
ssh -i ~/.ssh/master_rsa_key <ssh-opts> dev@<IP> 'sudo bash -s' \
  < ~/.cursor/skills/create-proxy-server/scripts/install_squid_proxy.sh
```

Optional env (set in the remote `sudo bash -s` wrapper if needed):

- `PROXY_PORT=3128` (default)
- `PROXY_USER=shai`
- `PROXY_PASS=1234!`
- `PROXY_HOME=/home/<login-user>` (default: `/home/$SUDO_USER` or `/root`)

The script:

1. Narrows Claroty `443 → 8090` prerouting to **local** destinations only (so Docker egress HTTPS is not MITM’d).
2. Adds **3128** (and usually **53**) to `tcp_accepted_ports` / nft set.
3. Writes Squid conf + htpasswd-style `passwd`.
4. Writes `$PROXY_HOME/proxy.sh` and starts the container (`-p 3128:3128`).
5. Self-tests CONNECT locally.

### Step 4: Verify

Expect from the install script (or re-run equivalent):

- `CONNECT … 200 Connection established` with `shai` / `1234!`
- `… 407 Proxy Authentication Required` with bad password

Quick remote status:

```bash
sudo ~/proxy.sh --status   # or /home/<user>/proxy.sh
ss -lntp | grep 3128
```

### Step 5: Report

Reply with a short table:

| Item | Value |
|------|-------|
| Proxy | `<IP>:3128` |
| Auth | `shai` / `1234!` |
| Helper | `/home/<user>/proxy.sh` |

## Notes

- Prefer **bridge** publish (`-p 3128:3128`), not `--network host` (AppArmor / `ipcCreate` failures on some SRA hosts).
- `claroty-firewall` may regenerate nft files; re-add **3128** / re-narrow **443→8090** if proxy or TLS-through-proxy breaks after platform reload.
- This is a **lab** forward proxy for xSA HTTP CONNECT tests, not production hardening.

## Related

- SSH / firewall: local skill `shai-access-sra-ssh`
- Installer: [scripts/install_squid_proxy.sh](scripts/install_squid_proxy.sh)
