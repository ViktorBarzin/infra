#!/usr/bin/env bash
#
# OS-major upgrade (Ubuntu do-release-upgrade). NOT in the auto-upgrade
# pipeline — minor apt patches are handled by unattended-upgrades + kured;
# K8s component bumps are handled by the k8s-version-upgrade agent. Run this
# script manually when bumping Ubuntu LTS major versions.
#
# See:
#   - infra/docs/runbooks/k8s-node-auto-upgrades.md  (apt + reboot)
#   - infra/docs/runbooks/k8s-version-upgrade.md     (kubeadm/kubelet/kubectl)

# sudo apt update && sudo apt autoremove -y && sudo apt upgrade -y
sudo do-release-upgrade
sudo apt update && sudo apt autoremove -y && sudo apt upgrade -y
