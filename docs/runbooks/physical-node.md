# Physical nodes

A Physical node is a Kubernetes node on its own hardware. Its secrets are on an encrypted State volume. The State volume opens only when the node can reach its Tang server in Sofia. The decision is ADR-0045. The terms are in `GLOSSARY.md`.

| Part | Where |
|---|---|
| Playbook | `playbooks/physical-node.yml`, group `physical_nodes` in `playbooks/inventory.ini` |
| Per-node settings | `playbooks/host_vars/<node>.yml` |
| Tang servers | `stacks/tang/main.tf`, one per node |
| Tang keys | Vault `secret/tang-<node>`: `sig.jwk`, `exc.jwk` (ESO copies every key of this path into the Tang pod) |
| Recovery passphrase | Vault `secret/physical-node-recovery-<node>`: `recovery_passphrase`, kept apart so it never reaches the Tang pod |
| Wi-Fi network | Vault `secret/wifi-<site>`: `ssid`, `psk` |
| Tether | `/usr/local/sbin/physical-node-tether`, source `playbooks/files/physical-node/` |

The first Physical node is `dell-worker`, the Dell Precision 5530 in London. It is an Opportunistic worker.

## How the node is built

- The OS root is not encrypted. The State volume is a LUKS2 partition, mounted at `/var/lib/state`.
- These paths are bind mounts from `/var/lib/state/<name>`: `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/containerd`, `/etc/cni/net.d`, `/var/lib/calico`, `/var/log/pods`, `/var/log/containers` and `/opt/actions-runner`.
- Each mountpoint is an empty directory with the immutable flag (`chattr +i`). When the volume is closed, nothing can write there on the plain root.
- `containerd.service` and `kubelet.service` have `RequiresMountsFor=` on all the bind mounts. They do not start while the volume is closed.
- journald keeps logs in memory. rsyslog and apport are removed. Core dumps, swap, suspend and hibernate are off. The lid switch does nothing. `/tmp` is a tmpfs.
- The node has the taint `node-role.viktorbarzin.me/opportunistic=true:NoSchedule`. Only pods that tolerate it run there.

## How the unlock works

1. At boot, systemd reads `/etc/crypttab`: `state UUID=<uuid> none luks,_netdev,nofail`.
2. `_netdev` puts the unlock after `network-online.target`, in `remote-cryptsetup.target`.
3. systemd asks for a password. `clevis-luks-askpass.path` sees the question and answers it with a key from Tang. It tries again until Tang answers.
4. `nofail` lets the boot finish without the volume. SSH works when Tang is down.
5. When the volume opens, systemd mounts it and the bind mounts, and containerd and kubelet start.

If the mounts time out before Tang answers, the Tether mounts them and starts containerd and kubelet.

## How the Tether works

`physical-node-tether.timer` runs `physical-node-tether` once a minute. Each run asks Tang for `/adv`.

| Tang | State volume | The Tether does |
|---|---|---|
| answers | open and mounted | nothing |
| answers | open, not mounted | mounts it and the bind mounts, starts containerd and kubelet |
| answers | closed | `clevis luks unlock`, mounts, starts containerd and kubelet |
| answers | boot unlock still running | nothing; Clevis finishes it |
| no answer for less than 10 minutes | any | records the time of the first failure in `/run/physical-node-tether/first-failure` |
| no answer for 10 minutes | open | stops kubelet and containerd, removes the pods, unmounts, closes the volume |

Read what it did:

```sh
journalctl -u physical-node-tether --since -1h
```

The Tether starts a unit only when it has just opened or mounted the volume. A kubelet that you stopped stays stopped.

## Add a machine

PXE provisioning comes later (ADR-0045). For now, install by hand.

1. **Install Ubuntu 26.04.** Make a separate partition for the State volume. Give it the GPT name `<node>-state`, for example `sgdisk -c 10:dell-state /dev/nvme0n1`. Do not put a filesystem on it. Make the user `wizard` with your SSH key. A machine with no wired port gets Ubuntu by `debootstrap`.
2. **Give the machine a fixed address.** Add a static DHCP lease on the Site router.
3. **Make the Tang keys.** Run this on the devvm. The keys stay in memory until Vault has them.

   ```sh
   node=dell-worker
   img=docker.io/padhihomelab/tang@sha256:3a9a5b1d07c70e97d6a3b56919acedf2abcd6b5e9ded132531123c719e0b267e
   d=$(mktemp -d -p "$XDG_RUNTIME_DIR")
   docker run --rm --entrypoint jose "$img" jwk gen -i '{"alg":"ES512"}' > "$d/sig.jwk"
   docker run --rm --entrypoint jose "$img" jwk gen -i '{"alg":"ECMR"}' > "$d/exc.jwk"
   vault kv put "secret/tang-$node" sig.jwk=@"$d/sig.jwk" exc.jwk=@"$d/exc.jwk"
   rm -r "$d"
   ```

4. **Add the Tang server.** Add the node to `local.nodes` in `stacks/tang/main.tf`, with a free MetalLB IP and the Site LAN in `source_ranges`. Commit, then `homelab tf apply tang`. From the new machine, `curl -sf http://<lb_ip>/adv` must return JSON.
5. **Store the Wi-Fi network**, once per Site. Write `{"ssid": "...", "psk": "..."}` to a file in `$XDG_RUNTIME_DIR`. Then run `vault kv put secret/wifi-<site> @<file>` and remove the file.
6. **Declare the node.** Add it to `[physical_nodes]` in `playbooks/inventory.ini`. Copy `playbooks/host_vars/dell-worker.yml` to `<node>.yml` and change the values. `state_device` is `/dev/disk/by-partlabel/<node>-state`.
7. **Claim the node:** `presence claim node:<node> --purpose "provision Physical node"`.
8. **Run the playbook as a dry run, then for real.** Run from the main checkout of the infra repo.

   ```sh
   ansible-playbook -i playbooks/inventory.ini playbooks/physical-node.yml --limit <node> --check --diff
   ansible-playbook -i playbooks/inventory.ini playbooks/physical-node.yml --limit <node>
   ```

   A dry run on a new machine skips the steps that need earlier ones, so it shows less than the real run.

   The playbook formats the State partition only if it holds nothing. If it holds a filesystem that can go, add `-e state_volume_wipe=true`.

9. **Reboot the node.** The boot unlock, `/tmp`, the lid setting, the Wi-Fi file, the NVIDIA module and the kubelet settings start at this boot.
10. **Check the result.**

    ```sh
    kubectl get node <node> -o wide        # Ready, with the taint and the labels
    ssh <node> 'lsblk -f; findmnt /var/lib/kubelet; systemctl status physical-node-tether.timer'
    ssh <node> 'journalctl -b -u systemd-cryptsetup@state -u clevis-luks-askpass'
    ```

11. **Run the dry run again.** It must report `changed=0`. Anything else is drift.
12. **Release the claim:** `presence release node:<node>`.

## Test the Tether

Do this on a node that runs nothing important. It stops all pods on the node.

1. Block Tang on the node: `sudo iptables -I OUTPUT -d <tang_ip> -j REJECT`.
2. Wait 11 minutes. `journalctl -u physical-node-tether` must show "State volume closed". `lsblk` must show no `state` mapping.
3. Remove the block: `sudo iptables -D OUTPUT -d <tang_ip> -j REJECT`.
4. Within 2 minutes the journal must show "State volume in use again". The node must become Ready.

## Open the volume without Tang

Use this when Tang is lost and the node must start.

```sh
vault kv get -field=recovery_passphrase secret/physical-node-recovery-<node>     # on the devvm
sudo cryptsetup open /dev/disk/by-partlabel/<node>-state state # on the node; type the passphrase
sudo mount /var/lib/state && sudo mount -a
sudo systemctl start containerd kubelet
```

The Tether closes the volume again after 10 minutes without Tang. Stop it first: `sudo systemctl stop physical-node-tether.timer`. Start it again when Tang is back.

## Rotate the Tang keys

Tang keeps a key whose file name starts with `.` for unlocks, but does not advertise it. Use this to move a node to new keys without downtime.

1. Read the secret into memory: `vault kv get -format=json secret/tang-<node> | jq .data.data > "$d/old.json"` (with `d` in `$XDG_RUNTIME_DIR`, as in "Add a machine").
2. Make a new `sig.jwk` and `exc.jwk` with the `docker run` commands from "Add a machine".
3. Write one secret with the new keys as `sig.jwk` and `exc.jwk`, the old keys as `.sig-old.jwk` and `.exc-old.jwk`. Use `vault kv put secret/tang-<node> @"$d/new.json"`.
4. Make ESO copy it now, and restart Tang:

   ```sh
   kubectl -n tang annotate externalsecret tang-<node> force-sync=$(date +%s) --overwrite
   kubectl -n tang rollout restart deployment tang-<node>
   ```

5. On the node, find the Tang slot and bind it to the new key: `sudo clevis luks list -d <state_device>`, then `sudo clevis luks regen -d <state_device> -s <slot>`.
6. Check the binding: `sudo clevis luks report -d <state_device> -s <slot>` must report no missing keys.
7. Write the secret again without the `.sig-old.jwk` and `.exc-old.jwk` keys. Force the sync and restart Tang again.
8. Reboot the node once to prove the unlock.
9. Remove the files: `rm -r "$d"`.

## After a theft

Do these steps in this order. Steps 1 and 2 stop the stolen disk from opening.

1. **Stop its Tang now.** `kubectl -n tang scale deployment tang-<node> --replicas=0`. This is a temporary step; step 3 makes it permanent.
2. **Delete its keys from Vault, with all versions:** `vault kv metadata delete secret/tang-<node>`. Keep `secret/physical-node-recovery-<node>` until the disk is wiped or recovered. Deleting the Vault secret alone is not enough: the Kubernetes Secret stays and Tang keeps serving it.
3. **Remove the node from `local.nodes` in `stacks/tang/main.tf`.** Commit, then `homelab tf apply tang`. This deletes the Deployment, the Service, the ExternalSecret and the Secret.
4. **Remove the node from the cluster:**

   ```sh
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force
   kubectl delete node <node>
   ```

5. **Change the Wi-Fi password** of the Site. The plain root holds it.
6. **Forget the SSH host keys.** The plain root holds them, so a thief can pose as the node. Run `ssh-keygen -R <node_ip>` and `ssh-keygen -R <node>` on the devvm and on every machine that connected to it. Remove the node from `[physical_nodes]` and delete its `host_vars` file.
7. **Remove any GitHub runner registration** for the node in the repository settings.

If the node was stolen while it was running, the volume was open. Then the kubelet client certificate in `/var/lib/kubelet/pki` was readable. Kubernetes cannot revoke a client certificate before it expires. The API server is reachable only from the Site LANs and the tunnel, so the certificate works only from there.

If the machine comes back, do not trust its OS. Install Ubuntu again and follow "Add a machine". The new install makes new SSH host keys.

## Remove a machine

1. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` and `kubectl delete node <node>`.
2. Remove it from `local.nodes` in `stacks/tang/main.tf` and apply. Delete `secret/tang-<node>`.
3. Remove it from `[physical_nodes]` and delete `playbooks/host_vars/<node>.yml`.

## Known limits

- **Versions.** The playbook installs containerd and kubeadm at the cluster's versions only on a new node. It does not upgrade a node. A node that was off during a `k8s-version-upgrade` run keeps its old kubelet; the playbook reports it.
- **Labels and taints** apply at registration. The playbook reports a difference and changes nothing.
- **GPU.** The node keeps a host NVIDIA driver (`gpu_driver`) and the labels `nvidia.com/gpu.deploy.driver=false` and `nvidia.com/gpu.deploy.container-toolkit=false`. The GPU Operator's DaemonSets tolerate only `nvidia.com/gpu`, so its device plugin does not run on a node with the Opportunistic worker taint.
- **Gates that wait for every node.** `kured-sentinel-gate` and the `k8s-version-upgrade` preflight both require all nodes Ready (`docs/runbooks/k8s-node-auto-upgrades.md`, `docs/runbooks/k8s-version-upgrade.md`). An Opportunistic worker that is off blocks them.
- **Other hostPath writers.** `calico-node` writes `/var/log/calico` and `tetragon` writes `/var/log/tetragon` on the plain root. Add a path to `state_binds` in the playbook if it holds secrets.
