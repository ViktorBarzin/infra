<main class="content">
	<h1>Architecture</h1>

	<section>
		<h2>Overview</h2>
		<p>The infrastructure runs on a single Dell R730 server (22 CPU cores, 142GB RAM) using Proxmox to manage virtual machines. Five of those VMs form a Kubernetes cluster that runs 70+ services.</p>
		<pre class="output">
Proxmox (Dell R730)
 ├── k8s-master  (10.0.20.100) — control plane
 ├── k8s-node1   (10.0.20.101) — GPU node (Tesla T4)
 ├── k8s-node2   (10.0.20.102) — worker
 ├── k8s-node3   (10.0.20.103) — worker
 ├── k8s-node4   (10.0.20.104) — worker
 ├── TrueNAS     (10.0.10.15)  — storage (NFS + iSCSI)
 └── pfSense     (10.0.20.1)   — firewall + gateway</pre>
	</section>

	<section>
		<h2>Networking</h2>
		<ul>
			<li><strong>Public domain</strong>: <code>viktorbarzin.me</code> — managed by Cloudflare</li>
			<li><strong>Internal domain</strong>: <code>viktorbarzin.lan</code> — managed by Technitium DNS</li>
			<li><strong>Ingress</strong>: Cloudflare → Traefik → services</li>
			<li><strong>VPN</strong>: Headscale (self-hosted Tailscale)</li>
		</ul>
	</section>

	<section>
		<h2>Storage</h2>
		<ul>
			<li><strong>NFS</strong> (<code>nfs-truenas</code>) — for app data (files, configs, media). Stored on TrueNAS.</li>
			<li><strong>iSCSI</strong> (<code>iscsi-truenas</code>) — for databases (PostgreSQL, MySQL). Block storage.</li>
		</ul>
	</section>

	<section>
		<h2>Service Tiers</h2>
		<p>Services are organized into tiers that control resource limits and restart priority:</p>
		<table>
			<thead><tr><th>Tier</th><th>Examples</th><th>Priority</th></tr></thead>
			<tbody>
			<tr><td><strong>0-core</strong></td><td>Traefik, DNS, VPN, Auth</td><td>Highest — never evicted</td></tr>
			<tr><td><strong>1-cluster</strong></td><td>Redis, Prometheus, CrowdSec</td><td>High</td></tr>
			<tr><td><strong>2-gpu</strong></td><td>Ollama, Immich ML, Whisper</td><td>Medium</td></tr>
			<tr><td><strong>3-edge</strong></td><td>Nextcloud, Paperless, Grafana</td><td>Normal</td></tr>
			<tr><td><strong>4-aux</strong></td><td>Dashy, PrivateBin, CyberChef</td><td>Low — evicted first under pressure</td></tr>
			</tbody>
		</table>
	</section>

	<section>
		<h2>Infrastructure as Code</h2>
		<p>Everything is managed with <strong>Terraform</strong> (via <strong>Terragrunt</strong>). Each service has its own stack:</p>
		<pre class="output">stacks/
 ├── platform/       ← core infra (22 modules)
 ├── url/            ← URL shortener (Shlink)
 ├── immich/         ← photo library
 ├── nextcloud/      ← file storage
 └── ... (70+ more)</pre>
		<p>Changes go through git: branch → PR → review → merge → CI applies automatically.</p>
	</section>
</main>

<style>
	.content { max-width: 768px; margin: 2rem auto; padding: 0 1rem; font-family: system-ui, -apple-system, sans-serif; line-height: 1.6; }
	.content h1 { border-bottom: 1px solid #e0e0e0; padding-bottom: 0.5rem; }
	.content h2 { margin-top: 2rem; color: #333; }
	.content pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; overflow-x: auto; }
	.content pre.output { background: #f5f5f5; color: #333; }
	.content code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
	section { margin: 2rem 0; }
	table { border-collapse: collapse; width: 100%; }
	th, td { border: 1px solid #ddd; padding: 0.5rem; text-align: left; }
	th { background: #f5f5f5; }
</style>
