[![Build Status](https://drone.viktorbarzin.me/api/badges/ViktorBarzin/infra/status.svg)](https://drone.viktorbarzin.me/ViktorBarzin/infra)

This repo contains my infra-as-code sources.

My infrastructure is built using Terraform, Kubernetes and CI/CD is done using Drone CI.

Read more by visiting my website:
https://viktorbarzin.me

# git-crypt setup

To decrypt the secrets, you need to setup [git-crypt](https://github.com/AGWA/git-crypt).

1. Install [git-crypt](https://github.com/AGWA/git-crypt).
2. Setup gpg keys on the machine
3. `git-crypt unlock`

This will unlock the secrets and will lock them on commit
