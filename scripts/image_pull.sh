#!/usr/bin/env bash

for n in $(kubectl get nodes -o wide | grep node | awk '{print $1}'); do 
    echo $n;
    kubectl drain $n --ignore-daemonsets --delete-emptydir-data && \
    ssh wizard@$n < image_pull_remote.sh
    # Check result
    kubectl get --raw "/api/v1/nodes/$n/proxy/configz" | jq '.kubeletconfig | {serializeImagePulls, maxParallelImagePulls}'
    kubectl uncordon $n
done
