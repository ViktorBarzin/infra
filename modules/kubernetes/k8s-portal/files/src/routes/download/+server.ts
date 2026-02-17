import type { RequestHandler } from './$types';
import { readFileSync } from 'fs';

const CLUSTER_SERVER = 'https://10.0.20.100:6443';
const OIDC_ISSUER = 'https://authentik.viktorbarzin.me/application/o/kubernetes/';
const OIDC_CLIENT_ID = 'kubernetes';

export const GET: RequestHandler = async ({ request }) => {
	const email = request.headers.get('x-authentik-email') || 'user';

	// Read CA cert from mounted ConfigMap
	let caCert = '';
	try {
		caCert = readFileSync('/config/ca.crt', 'utf-8');
	} catch {
		// CA cert not available
	}

	const caCertBase64 = Buffer.from(caCert).toString('base64');
	const sanitizedEmail = email.replace(/[^a-zA-Z0-9@._-]/g, '');

	const kubeconfig = `apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${caCertBase64}
  name: home-cluster
contexts:
- context:
    cluster: home-cluster
    user: oidc-${sanitizedEmail}
  name: home-cluster
current-context: home-cluster
users:
- name: oidc-${sanitizedEmail}
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
      interactiveMode: IfAvailable
`;

	return new Response(kubeconfig, {
		headers: {
			'Content-Type': 'application/yaml',
			'Content-Disposition': `attachment; filename="kubeconfig-home-cluster.yaml"`
		}
	});
};
