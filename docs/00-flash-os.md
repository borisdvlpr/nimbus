# 00 — Flash the OS (Ubuntu Server 24.04 LTS, arm64) + join the tailnet

This is the one step you do with your hands. Everything after it happens over the network.

The goal is narrow: end up with a Raspberry Pi that joins your Tailscale tailnet on first boot
and answers over **Tailscale SSH**, so Ansible can take it from there. There's no traditional
SSH to configure — that's deliberate, and the rest of the build depends on it.

## What you'll need

- Raspberry Pi 4 (4 GB)
- A microSD card (16 GB+) — or, later, a USB SSD
- A **Tailscale account**, with a device of your own already on the tailnet (your workstation)
- A **Tailscale auth key** (you'll create it below)
- An ACL that allows the node and your SSH access (example below)

## 0. Prepare Tailscale (one-time)

### Auth key

Head to the Tailscale admin console → **Settings → Keys → Generate auth key**. The key needs
four properties:

- **Pre-authorized**, so the node registers itself without you approving it by hand
- **Single-use** — it's consumed at first boot, and the device stays registered afterwards, so
  the plaintext copy left on the card becomes useless
- **Non-ephemeral**, because the node has to survive reboots
- **Tagged** with `tag:nimbus`

Treat the key like a password. It goes into your local cloud-init copy and must never be
committed.

### ACL

Over in **Access Controls**, make sure the tag exists and that your own identity is allowed to
SSH into it. Here's a minimal policy (HuJSON):

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

> If you want this fully reproducible too, you can manage the policy as code — Tailscale
> supports GitOps for ACLs and has a Terraform provider. That lives outside this repository
> and is entirely optional.

## 1. Get the image

Download **Ubuntu Server 24.04 LTS (64-bit, arm64) for Raspberry Pi** from
<https://ubuntu.com/download/raspberry-pi>, or pick it up through the Raspberry Pi Imager
(*Other general-purpose OS → Ubuntu → Ubuntu Server 24.04 LTS (64-bit)*).

## 2. Flash it

Raspberry Pi Imager, `balenaEtcher`, or plain `dd` — whichever you prefer.

> One catch if you use Raspberry Pi Imager: **skip its OS customization screen**. We configure
> the user and network declaratively with cloud-init, and the Imager's settings would overwrite
> our `user-data`.

## 3. Apply the headless cloud-init config (with your auth key)

Once flashing finishes, the card has two partitions. Mount the small FAT one labeled
**`system-boot`**, then:

1. Make a local, uncommitted copy of the template and drop your auth key into it:
   ```bash
   cp cloud-init/user-data cloud-init/user-data.local   # user-data.local is git-ignored
   # edit cloud-init/user-data.local: replace tskey-auth-REPLACE_ME with your real key
   ```
2. Copy `cloud-init/user-data.local` over the `user-data` file on the `system-boot` partition.
3. Leave the existing `meta-data` file alone — an empty file is fine, and the image ships one.
4. Optionally, set a DHCP reservation on your router for a stable LAN address during first
   boot. It only matters until Tailscale is up; after that you use the tailnet name.

Eject the card.

## 4. First boot

Insert the card, connect Ethernet (recommended), and power on. cloud-init creates the `nimbus`
user, installs Tailscale, and runs `tailscale up --ssh`. Give it a few minutes — it may reboot
once along the way. The node should then show up in your Tailscale admin console, auto-approved
by the pre-authorized key, under the name `nimbus`.

## 5. Verify reachability over the tailnet

From any device on your tailnet:

```bash
tailscale status            # nimbus should be listed
ssh nimbus@nimbus           # Tailscale SSH — no key/password; auth is your tailnet identity
```

If you can log in and `sudo` without a password prompt, you're done here.

## Troubleshooting

- Plug a monitor and keyboard into the Pi and run `cloud-init status --wait`, then
  `tailscale status`.
- cloud-init keeps its logs at `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`.
- If the node never appears on the tailnet, check that the auth key was pasted in correctly and
  is still valid and unused, and that `tag:nimbus` exists in your ACL.
- If `ssh nimbus@nimbus` is refused, revisit the `ssh` ACL rule above and confirm MagicDNS is
  enabled.

## Re-flashing later (clean rebuild)

A fresh flash registers a **new** tailnet node. Remove the old `nimbus` entry from the admin
console first so the name stays clean — otherwise the new node may come back with a `-1` suffix.
Everything else is restored by Ansible and Flux.

## Next

Set `ansible_host` in `ansible/inventory.ini` to the node's tailnet name (`nimbus`), then move
on to the [Ansible bootstrap](./01-bootstrap.md). That's where the host gets its real
configuration: the unused system sshd is masked, the memory cgroup is enabled, sysctls are
raised, Docker and tooling go on, the Kind cluster is created (with the API server bound to the
tailnet and the right cert SANs), and Flux is bootstrapped.
