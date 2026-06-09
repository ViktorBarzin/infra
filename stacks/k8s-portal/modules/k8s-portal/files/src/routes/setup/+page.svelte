<main>
	<h1>Setup Instructions</h1>

	<section>
		<h2>Quick Setup (one command)</h2>
		<p>Run this in your terminal to install everything and configure kubectl automatically:</p>
		<h3>macOS</h3>
		<pre>bash &lt;(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=mac)</pre>
		<h3>Linux</h3>
		<pre>bash &lt;(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=linux)</pre>
	</section>

	<section>
		<h2>Manual Setup</h2>

		<h3>1. Install kubectl</h3>
		<h4>macOS</h4>
		<pre>brew install kubectl</pre>
		<h4>Linux</h4>
		<pre>curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/</pre>

		<h3>2. Install kubelogin (OIDC plugin)</h3>
		<h4>macOS</h4>
		<pre>brew install int128/kubelogin/kubelogin</pre>
		<h4>Linux</h4>
		<pre>curl -LO https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip
unzip kubelogin_linux_amd64.zip && sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
rm kubelogin_linux_amd64.zip</pre>

		<h3>3. Download and use your kubeconfig</h3>
		<pre>
mkdir -p ~/.kube

# Download from the portal (requires auth cookie from browser)
# Or use the download button on the portal homepage

# Set the KUBECONFIG environment variable
export KUBECONFIG=~/.kube/config-home

# Test access (opens browser for login)
kubectl get namespaces
		</pre>
	</section>

	<p><a href="/">&#8592; Back to portal</a></p>
</main>

<style>
	main {
		max-width: 640px;
		margin: 2rem auto;
		font-family: system-ui;
	}
	pre {
		background: #1e1e1e;
		color: #d4d4d4;
		padding: 1rem;
		border-radius: 6px;
		overflow-x: auto;
	}
	section {
		margin: 2rem 0;
	}
	h4 {
		margin: 0.5rem 0 0.25rem;
		color: #666;
	}
</style>
