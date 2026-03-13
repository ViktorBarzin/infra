#!/bin/bash
# Setup script for automated monitoring environment
# Ensures health check scripts have access to kubeconfig

echo "=== Setting up automated monitoring environment ==="

# Copy kubeconfig to location expected by health check scripts
if [ -f /home/node/.openclaw/kubeconfig ]; then
    cp /home/node/.openclaw/kubeconfig /workspace/infra/config
    echo "✅ Kubeconfig copied to /workspace/infra/config"
else
    echo "❌ Source kubeconfig not found at /home/node/.openclaw/kubeconfig"
    exit 1
fi

# Test health check access
echo ""
echo "Testing health check script access..."
cd /workspace/infra
if KUBECONFIG="" timeout 30 bash .claude/cluster-health.sh --quiet > /dev/null 2>&1; then
    echo "✅ Health check script can access cluster"
else
    echo "❌ Health check script cannot access cluster"
    exit 1
fi

echo ""
echo "✅ Automated monitoring environment setup complete"
echo "📊 Cron health checks will now work properly"