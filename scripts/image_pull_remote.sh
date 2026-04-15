#!/usr/bin/env bash

# Containerd
sudo sed -i 's/.*max_concurrent_downloads.*/max_concurrent_downloads = 5/g' /etc/containerd/config.toml 
sudo systemctl restart containerd

# Kubelet
#sed serializeImagePulls: false # Allow container images to be downloaded in parallel
#maxParallelImagePulls: 20 # To limit the number of parallel image pulls.

sudo sed -i '/serializeImagePulls:/d' /var/lib/kubelet/config.yaml && \
sudo sed -i '/maxParallelImagePulls:/d' /var/lib/kubelet/config.yaml && \
echo -e 'serializeImagePulls: false\nmaxParallelImagePulls: 5' | sudo tee -a /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
