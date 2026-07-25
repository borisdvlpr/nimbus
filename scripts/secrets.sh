#!/usr/bin/env bash

# Set up the two off-git secrets nimbus needs. This is a command list, not a
# script to run blind — read each step, then copy the lines you need.

# 1. generate your age keypair (once, on your workstation)
#    the guard makes this safe to re-run: it will NOT overwrite an existing key,
#    which would leave every committed *.sops.yaml permanently undecryptable.
mkdir -p ~/.config/sops/age
[ -f ~/.config/sops/age/keys.txt ] || age-keygen -o ~/.config/sops/age/keys.txt
grep '^# public key:' ~/.config/sops/age/keys.txt      # the age1... recipient

# 2. put the public key into .sops.yaml (replace the placeholder on the `age:` line)

# 3. set a real password in the grafana secret, then encrypt it in place
sops --encrypt --in-place infrastructure/observability/grafana-admin.sops.yaml

# 4. commit both files (.sops.yaml plaintext, grafana secret now encrypted)
git add .sops.yaml infrastructure/observability/grafana-admin.sops.yaml

# 5. create the repo deploy key used by `flux bootstrap` (once)
#    no passphrase: the flux_bootstrap role passes --private-key-file with no --password.
[ -f ~/.ssh/nimbus_deploy ] || ssh-keygen -t ed25519 -f ~/.ssh/nimbus_deploy -C "nimbus flux bootstrap" -N ""
cat ~/.ssh/nimbus_deploy.pub
#    -> add that public key to the repo's Deploy keys WITH "Allow write access"
#       (flux commits its own components into clusters/nimbus/flux-system/)
#    verify:  ssh -i ~/.ssh/nimbus_deploy -T git@github.com