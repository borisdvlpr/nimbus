# 00 — Flash the OS (Ubuntu Server 24.04 LTS, arm64) + join the tailnet

This is the only inherently physical, manual step in the whole bootstrap. The goal is narrow:
produce a Raspberry Pi that joins your Tailscale tailnet on first boot and is reachable over
**Tailscale SSH**, so Ansible can take over the network. There is no traditional SSH to configure.

## You need

- Raspberry Pi 4 (4 GB)
- A microSD card (16 GB+) — or, later, a USB SSD
- A **Tailscale account** and a device of your own already on the tailnet (your workstation)
- A **Tailscale auth key** (created below)
- An ACL that allows the node and your SSH access (example below)

## 0. Prepare Tailscale (one-time)

### Auth key

In the Tailscale admin console → **Settings → Keys → Generate auth key**, create a key that is:

- **Pre-authorized** (so the node registers without manual approval)
- **Single-use** (it is consumed at first boot; the device stays registered afterward, so the
  plaintext key on the card becomes useless)
- **Non-ephemeral** (the node must persist across reboots)
- **Tagged** with `tag:nimbus`

Keep this key secret — it goes into your local cloud-init copy and must never be committed.

### ACL

In **Access Controls**, make sure the tag exists and that you may SSH into it. A minimal example
(HuJSON):

```jsonc
{
  "tagOwners": {
    "tag:nimbus": ["autogroup:admin"]
  },
  "ssh": [
    {
      // Tailscale SSH: let your tailnet identity log in to the node as the nimbus user.
      // action "accept" (not "check") avoids interactive re-auth, which matters for Ansible.
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:nimbus"],
      "users": ["nimbus", "root"]
    }
  ]
}
```

> For full reproducibility you can manage this policy as code (Tailscale supports GitOps for ACLs
> and has a Terraform provider). That lives outside this repository and is optional.

## 1. Get the image

Download **Ubuntu Server 24.04 LTS (64-bit, arm64) for Raspberry Pi**, from
<https://ubuntu.com/download/raspberry-pi> or via the Raspberry Pi Imager
(*Other general-purpose OS → Ubuntu → Ubuntu Server 24.04 LTS (64-bit)*).

## 2. Flash it

Use Raspberry Pi Imager, `balenaEtcher`, or `dd`.

> If you use Raspberry Pi Imager, **do not apply its OS customization**. We configure the user and
> network declaratively with cloud-init, and the Imager's settings would overwrite our `user-data`.

## 3. Apply the headless cloud-init config (with your auth key)

After flashing, the card has two partitions. Mount the small FAT partition labeled **`system-boot`**.

1. Make a local, uncommitted copy of the template and put your auth key in it:
   ```bash
   cp cloud-init/user-data cloud-init/user-data.local   # user-data.local is git-ignored
   # edit cloud-init/user-data.local: replace tskey-auth-REPLACE_ME with your real key
   ```
2. Copy `cloud-init/user-data.local` over the `user-data` file on the `system-boot` partition.
3. Leave the existing `meta-data` file in place (an empty file is fine — the image ships one).
4. (Optional) For a stable LAN address during first boot, set a DHCP reservation on your router.
   It only matters until Tailscale is up; after that you use the tailnet name.

Eject the card.

## 4. First boot

Insert the card, connect Ethernet (recommended), and power on. cloud-init will create the `nimbus`
user, install Tailscale, and run `tailscale up --ssh`. This can take a few minutes and may reboot
once. The node should then appear in your Tailscale admin console (auto-approved by the
pre-authorized key) with the name `nimbus`.

## 5. Verify reachability over the tailnet

From any device on your tailnet:

```bash
tailscale status            # nimbus should be listed
ssh nimbus@nimbus           # Tailscale SSH — no key/password; auth is your tailnet identity
```

If you can log in and have passwordless `sudo`, this step is done.

## Troubleshooting

- On a monitor/keyboard attached to the Pi: `cloud-init status --wait`, then `tailscale status`.
- cloud-init logs: `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`.
- If the node never appears in the tailnet: check the auth key was filled in correctly and is still
  valid/unused, and that `tag:nimbus` exists in your ACL.
- If `ssh nimbus@nimbus` is refused: confirm the `ssh` ACL rule above and that MagicDNS is enabled.

## Re-flashing later (clean rebuild)

A fresh flash registers a **new** tailnet node. Remove the old `nimbus` entry from the admin console
first so the name stays clean (otherwise the new node may get a `-1` suffix). Everything else is
restored by Ansible + Flux.

## Next

Set `ansible_host` in `ansible/inventory.ini` to the node's tailnet name (`nimbus`), then run the
[Ansible bootstrap](./01-bootstrap.md), which masks the unused system sshd, enables the memory cgroup,
raises sysctls, installs Docker and tooling, creates the Kind cluster (binding the API server on the
tailnet with the right cert SANs), and bootstraps Flux.
