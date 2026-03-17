<main class="content">
	<h1>How to Contribute</h1>

	<section>
		<h2>Workflow</h2>
		<ol>
			<li><strong>Create a branch</strong>: <code>git checkout -b fix/my-change</code></li>
			<li><strong>Make your changes</strong> in <code>stacks/&lt;service&gt;/main.tf</code></li>
			<li><strong>Push and open a PR</strong>: <code>git push -u origin fix/my-change</code></li>
			<li><strong>Viktor reviews</strong> and merges</li>
			<li><strong>CI applies</strong> automatically — Slack notification when done</li>
		</ol>
	</section>

	<section>
		<h2>What you CAN change</h2>
		<ul>
			<li>Service configurations (image tags, environment variables, resource limits)</li>
			<li>New services (add a new stack under <code>stacks/</code>)</li>
			<li>Ingress routes, health probes, replica counts</li>
		</ul>
	</section>

	<section>
		<h2>What needs Viktor's review</h2>
		<ul>
			<li>CI pipeline changes (<code>.woodpecker/</code>)</li>
			<li>Terragrunt configuration (<code>terragrunt.hcl</code>)</li>
			<li>Secrets configuration (<code>.sops.yaml</code>)</li>
			<li>Core platform modules (<code>stacks/platform/</code>)</li>
		</ul>
	</section>

	<section>
		<h2 class="danger-header">NEVER do these</h2>
		<div class="callout danger">
			<ul>
				<li><strong>Never <code>kubectl apply/edit/patch</code></strong> — all changes go through Terraform</li>
				<li><strong>Never put secrets in code</strong> — ask Viktor to add them to the encrypted secrets file</li>
				<li><strong>Never restart NFS on TrueNAS</strong> — causes cluster-wide mount failures</li>
				<li><strong>Never push directly to master</strong> — always use a PR</li>
			</ul>
		</div>
	</section>

	<section>
		<h2>Need a new secret?</h2>
		<p>Comment on your PR: "I need a database password for my-service." Viktor will add it to the encrypted secrets file and push to your branch.</p>
		<p>Then reference it in your Terraform: <code>var.my_service_db_password</code></p>
	</section>

	<section>
		<h2>Namespace Owner Workflow</h2>
		<p>If you are a namespace owner, you can deploy your own apps:</p>
		<ol>
			<li>Clone the infra repo: <code>git clone https://github.com/ViktorBarzin/infra.git</code></li>
			<li>Copy the template: <code>cp -r stacks/_template stacks/your-app</code></li>
			<li>Rename: <code>mv stacks/your-app/main.tf.example stacks/your-app/main.tf</code></li>
			<li>Edit <code>main.tf</code> — replace all <code>&lt;placeholders&gt;</code></li>
			<li>Store secrets in Vault: <code>vault kv put secret/your-username/your-app KEY=value</code></li>
			<li>Add your app domain to your <code>domains</code> list in Vault KV</li>
			<li>Submit a PR, get it reviewed</li>
			<li>After merge, admin runs <code>terragrunt apply</code></li>
		</ol>
	</section>

	<section>
		<h2>CI Pipeline Template</h2>
		<p>Create a <code>.woodpecker.yml</code> in your app's Forgejo repo:</p>
		<pre>{`steps:
  - name: build
    image: woodpeckerci/plugin-docker-buildx
    settings:
      repo: your-dockerhub-user/myapp
      tag: ["\${CI_PIPELINE_NUMBER}", "latest"]
      username:
        from_secret: dockerhub-username
      password:
        from_secret: dockerhub-token
      platforms: linux/amd64

  - name: deploy
    image: hashicorp/vault:1.18.1
    commands:
      - export VAULT_ADDR=http://vault-active.vault.svc.cluster.local:8200
      - export VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login
          role=ci jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
      - KUBE_TOKEN=$(vault write -field=service_account_token
          kubernetes/creds/YOUR_NAMESPACE-deployer
          kubernetes_namespace=YOUR_NAMESPACE)
      - kubectl --server=https://kubernetes.default.svc
          --token=$KUBE_TOKEN
          --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          -n YOUR_NAMESPACE set image deployment/myapp
          myapp=your-dockerhub-user/myapp:\${CI_PIPELINE_NUMBER}`}</pre>
	</section>

	<section>
		<h2>Need a secret for your app?</h2>
		<p>As a namespace owner, you manage your own secrets in Vault:</p>
		<pre>vault kv put secret/your-username/your-app DB_PASSWORD=mysecret API_KEY=abc123</pre>
		<p>Then reference them in your Terraform using a <code>data "vault_kv_secret_v2"</code> block.</p>
	</section>
</main>

<style>
	.content { max-width: 768px; margin: 2rem auto; padding: 0 1rem; font-family: system-ui, -apple-system, sans-serif; line-height: 1.6; }
	.content h1 { border-bottom: 1px solid #e0e0e0; padding-bottom: 0.5rem; }
	.content h2 { margin-top: 2rem; color: #333; }
	.content code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
	section { margin: 2rem 0; }
	.callout { padding: 1rem; border-radius: 6px; margin: 1rem 0; }
	.callout.danger { background: #f8d7da; border-left: 4px solid #dc3545; }
	.danger-header { color: #dc3545; }
</style>
