#!/usr/bin/env bash

# run for all nodes using :
# for n in $(kbn | grep 'k8s-node' | awk '{print $1}'); do echo $n; kb drain $n --ignore-daemonsets --delete-emptydir-data; s wizard@$n 'bash -s' <update_k8s.sh; kb uncordon $n; done

set -e
export stable_version='1.34'  # change me
export release="$stable_version.2"  # change me

echo "Upgrading to $stable_version"

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$stable_version/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$stable_version/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes

sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update 
sudo apt-get install -y kubeadm="$release-*" 

HOSTNAME=$(hostname)
SEARCH_STR="master"

if [[ "$HOSTNAME" == *"$SEARCH_STR"* ]]; then
    echo "Upgrading master"
    sudo kubeadm upgrade plan && sudo kubeadm upgrade apply v$release -y
else
    echo "Upgrading worker"
    sudo kubeadm upgrade node 
fi

sudo apt-get install -y kubelet="$release-*" kubectl="$release-*"
sudo apt-mark hold kubeadm kubelet kubectl


sudo systemctl daemon-reload
sudo systemctl restart kubelet
