#!/usr/bin/env bash

echo 'KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --pod-infra-container-image=k8s.gcr.io/pause:3.7 --rotate-certificates=true --rotate-server-certificates=true"' | sudo tee /var/lib/kubelet/kubeadm-flags.env

sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Aprprove all csrs:
# for csr in $(kb get csr | grep Pending | awk '{print $1}'); do echo $csr; kb certificate approve $csr; done
