#!/bin/bash

# Simple and reliable containerd registry mirror manager
# Usage: ./registry-mirror.sh [--add|--remove] [mirror_url]
# Docs - https://github.com/containerd/containerd/blob/main/docs/cri/registry.md
# To apply on all nodes (tail +3 skips master node):
# for node in $(kubectl get nodes -o wide | awk '{print $6}' | tail -n +3); do cat node_registry_manager.sh | s wizard@$node "sudo bash -s -- --add http://192.168.1.10:5000"; done

CONFIG_FILE="/etc/containerd/config.toml"
BACKUP_FILE="/etc/containerd/config.toml.bak"

# Validate environment
[ -f "$CONFIG_FILE" ] || { echo "Error: $CONFIG_FILE not found" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Error: Requires root privileges" >&2; exit 1; }

add_mirror() {
    local mirror_url="$1"
    
    # Create backup
    cp -p "$CONFIG_FILE" "$BACKUP_FILE"
    
    # Check if mirror already exists
    if grep -q "endpoint = \[.*\"$mirror_url\".*\]" "$CONFIG_FILE"; then
        echo "Mirror already exists: $mirror_url"
        return 0
    fi

    # Check if docker.io section exists
    if grep -q "^\[plugins\.\"io\.containerd\.grpc\.v1\.cri\"\.registry\.mirrors\.\"docker.io\"\]" "$CONFIG_FILE"; then
        # Append to existing section
        sed -i "/^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\."docker.io"\]/a \  endpoint = [\"$mirror_url\"]" "$CONFIG_FILE"
    else
        # Add new section after registry.mirrors
        if grep -q "^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\]" "$CONFIG_FILE"; then
            sed -i "/^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\]/a \\n[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"docker.io\"]\n  endpoint = [\"$mirror_url\"]" "$CONFIG_FILE"
        else
            # Add complete new section
            echo -e "\n[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"docker.io\"]\n  endpoint = [\"$mirror_url\"]" >> "$CONFIG_FILE"
        fi
    fi
    
    echo "Added mirror: $mirror_url"
}

remove_mirror() {
    local mirror_url="$1"
    
    # Create backup
    cp -p "$CONFIG_FILE" "$BACKUP_FILE"
    
    # Remove the specific mirror URL
    sed -i "/endpoint = \[.*\"$mirror_url\".*\]/d" "$CONFIG_FILE"
    
    # Clean up empty sections
    sed -i '/^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\."docker.io"\]$/,/^\[/{//!d}' "$CONFIG_FILE"
    sed -i '/^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\."docker.io"\]$/d' "$CONFIG_FILE"
    
    # Clean up multiple empty lines
    sed -i '/^$/N;/^\n$/D' "$CONFIG_FILE"
    
    echo "Removed mirror: $mirror_url"
}

restart_containerd() {
    echo "Restarting containerd..."
    if systemctl restart containerd; then
        echo "Successfully restarted containerd"
        return 0
    else
        echo "Error: Failed to restart containerd" >&2
        return 1
    fi
}

case "$1" in
    --add)
        [ -z "$2" ] && { echo "Error: Mirror URL required" >&2; exit 1; }
        add_mirror "$2"
        restart_containerd || exit 1
        ;;
    --remove)
        [ -z "$2" ] && { echo "Error: Mirror URL required" >&2; exit 1; }
        remove_mirror "$2"
        restart_containerd || exit 1
        ;;
    *)
        echo "Usage: $0 [--add|--remove] [mirror_url]" >&2
        echo "Examples:" >&2
        echo "  Add mirror:    $0 --add https://registry.example.com" >&2
        echo "  Remove mirror: $0 --remove https://registry.example.com" >&2
        exit 1
        ;;
esac

exit 0