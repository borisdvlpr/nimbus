#!/usr/bin/env bash

# 1. generate your age keypair (once, on your workstation)
age-keygen -o ~/.config/sops/age/keys.txt      # prints the public key: age1...

# 2. put the public key into .sops.yaml (replace the placeholder on the `age:` line)

# 3. set a real password in the grafana secret, then encrypt it in place
sops --encrypt --in-place infrastructure/observability/grafana-admin.sops.yaml

# 4. commit both files (.sops.yaml plaintext, grafana secret now encrypted)
git add .sops.yaml infrastructure/observability/grafana-admin.sops.yaml
