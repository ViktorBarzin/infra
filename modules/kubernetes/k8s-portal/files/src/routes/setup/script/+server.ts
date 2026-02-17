import type { RequestHandler } from './$types';
import { readFileSync } from 'fs';

const CLUSTER_SERVER = 'https://10.0.20.100:6443';
const OIDC_ISSUER = 'https://authentik.viktorbarzin.me/application/o/kubernetes/';
const OIDC_CLIENT_ID = 'kubernetes';
const PORTAL_URL = 'https://k8s-portal.viktorbarzin.me';

export const GET: RequestHandler = async ({ url }) => {
	const os = url.searchParams.get('os') || 'mac';

	let caCert = '';
	try {
		caCert = readFileSync('/config/ca.crt', 'utf-8');
	} catch {
		// CA cert not available
	}
	const caCertBase64 = Buffer.from(caCert).toString('base64');

	const kubeconfigContent = `apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${caCertBase64}
  name: home-cluster
contexts:
- context:
    cluster: home-cluster
    user: oidc-user
  name: home-cluster
current-context: home-cluster
users:
- name: oidc-user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      args:
        - oidc-login
        - get-token
        - --oidc-issuer-url=${OIDC_ISSUER}
        - --oidc-client-id=${OIDC_CLIENT_ID}
        - --oidc-extra-scope=email
        - --oidc-extra-scope=profile
        - --oidc-extra-scope=groups
      interactiveMode: IfAvailable`;

	const escapedKubeconfig = kubeconfigContent.replace(/'/g, "'\\''");

	let script: string;

	if (os === 'linux') {
		script = `#!/bin/bash
set -e

echo "=== Kubernetes Cluster Setup ==="
echo ""

# Use sudo if available, otherwise install directly (e.g. in containers running as root)
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null; then
    SUDO="sudo"
fi

# Determine install directory
INSTALL_DIR="/usr/local/bin"
if [ ! -w "\$INSTALL_DIR" ] && [ -z "\$SUDO" ]; then
    INSTALL_DIR="\$HOME/.local/bin"
    mkdir -p "\$INSTALL_DIR"
    export PATH="\$INSTALL_DIR:\$PATH"
fi

# Install kubectl
if command -v kubectl &>/dev/null; then
    echo "[OK] kubectl already installed"
else
    echo "[..] Installing kubectl..."
    KUBECTL_VERSION=\$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -fsSLO "https://dl.k8s.io/release/\${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl && \$SUDO mv kubectl "\$INSTALL_DIR/"
    echo "[OK] kubectl installed"
fi

# Install kubelogin
if command -v kubectl-oidc_login &>/dev/null; then
    echo "[OK] kubelogin already installed"
else
    echo "[..] Installing kubelogin..."
    KUBELOGIN_VERSION=\$(curl -fsSL -o /dev/null -w "%{url_effective}" https://github.com/int128/kubelogin/releases/latest | grep -o '[^/]*\$')
    curl -fsSLO "https://github.com/int128/kubelogin/releases/download/\${KUBELOGIN_VERSION}/kubelogin_linux_amd64.zip"
    unzip -o kubelogin_linux_amd64.zip kubelogin -d /tmp
    \$SUDO mv /tmp/kubelogin "\$INSTALL_DIR/kubectl-oidc_login"
    rm -f kubelogin_linux_amd64.zip
    echo "[OK] kubelogin installed"
fi

# Write kubeconfig
mkdir -p ~/.kube
cat > ~/.kube/config-home << 'KUBECONFIG_EOF'
${escapedKubeconfig}
KUBECONFIG_EOF
echo "[OK] Kubeconfig written to ~/.kube/config-home"

# Add KUBECONFIG to shell profile
SHELL_RC=~/.bashrc
[ -f ~/.zshrc ] && SHELL_RC=~/.zshrc
if ! grep -q 'config-home' "\$SHELL_RC" 2>/dev/null; then
    echo 'export KUBECONFIG=~/.kube/config-home' >> "\$SHELL_RC"
    echo "[OK] Added KUBECONFIG to \$SHELL_RC"
fi
export KUBECONFIG=~/.kube/config-home

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Run 'kubectl get namespaces' to test (opens browser for login)."
echo "You may need to restart your shell or run: export KUBECONFIG=~/.kube/config-home"
`;
	} else {
		script = `#!/bin/bash
set -e

echo "=== Kubernetes Cluster Setup ==="
echo ""

# Check for Homebrew
if ! command -v brew &>/dev/null; then
    echo "[!!] Homebrew not found. Install it first:"
    echo '     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
fi

# Install kubectl
if command -v kubectl &>/dev/null; then
    echo "[OK] kubectl already installed ($(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | cut -d'"' -f4))"
else
    echo "[..] Installing kubectl..."
    brew install kubectl
    echo "[OK] kubectl installed"
fi

# Install kubelogin
if command -v kubectl-oidc_login &>/dev/null; then
    echo "[OK] kubelogin already installed"
else
    echo "[..] Installing kubelogin..."
    brew install int128/kubelogin/kubelogin
    echo "[OK] kubelogin installed"
fi

# Write kubeconfig
mkdir -p ~/.kube
cat > ~/.kube/config-home << 'KUBECONFIG_EOF'
${escapedKubeconfig}
KUBECONFIG_EOF
echo "[OK] Kubeconfig written to ~/.kube/config-home"

# Add KUBECONFIG to shell profile
SHELL_RC=~/.zshrc
[ ! -f ~/.zshrc ] && SHELL_RC=~/.bashrc
if ! grep -q 'config-home' "\$SHELL_RC" 2>/dev/null; then
    echo 'export KUBECONFIG=~/.kube/config-home' >> "\$SHELL_RC"
    echo "[OK] Added KUBECONFIG to \$SHELL_RC"
fi
export KUBECONFIG=~/.kube/config-home

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Run 'kubectl get namespaces' to test (opens browser for login)."
echo "You may need to restart your shell or run: export KUBECONFIG=~/.kube/config-home"
`;
	}

	return new Response(script, {
		headers: {
			'Content-Type': 'text/plain; charset=utf-8'
		}
	});
};
