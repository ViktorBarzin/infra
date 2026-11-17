/**
 * One Kubernetes exec over WebSocket (subprotocol v5.channel.k8s.io), the
 * way Cloud's console runs a shell or psql session (the cloud repo's
 * src/server/kube-exec.server.ts), for cloud-access.test.sh. kubectl exec
 * falls back to SPDY when the WebSocket upgrade is refused, and SPDY needs
 * only create on pods/exec, so only a WebSocket client shows that the
 * console's role is enough.
 *
 * Usage: bun exec-ws.ts <server> <ca file> <token file> <namespace> <pod> <container> <command...>
 *
 * Closes stdin at once, prints stdout and stderr, and exits with the
 * command's exit code; 100 when the upgrade or the exec was refused.
 */
const [server, caFile, tokenFile, namespace, pod, container, ...command] =
	process.argv.slice(2);
if (!server || !caFile || !tokenFile || !namespace || !pod || !container || command.length === 0) {
	console.error("usage: bun exec-ws.ts <server> <ca> <token> <ns> <pod> <container> <command...>");
	process.exit(2);
}
const query = new URLSearchParams();
for (const arg of command) query.append("command", arg);
query.set("container", container);
query.set("stdin", "true");
query.set("stdout", "true");
query.set("stderr", "true");
const url = `${server.replace(/^https:/, "wss:")}/api/v1/namespaces/${encodeURIComponent(namespace)}/pods/${encodeURIComponent(pod)}/exec?${query}`;
const token = (await Bun.file(tokenFile).text()).trim();
const ca = await Bun.file(caFile).text();
const BunWebSocket = WebSocket as unknown as new (
	url: string,
	options: Bun.WebSocketOptions,
) => WebSocket;
const ws = new BunWebSocket(url, {
	headers: { authorization: `Bearer ${token}` },
	protocols: ["v5.channel.k8s.io"],
	tls: { ca },
});
ws.binaryType = "arraybuffer";
let code = 100;
const done = new Promise<void>((resolve) => {
	ws.onopen = () => ws.send(new Uint8Array([255, 0]));
	ws.onmessage = (event: MessageEvent) => {
		const bytes = new Uint8Array(event.data as ArrayBuffer);
		const text = new TextDecoder().decode(bytes.subarray(1));
		if (bytes[0] === 1) process.stdout.write(text);
		if (bytes[0] === 2) process.stderr.write(text);
		if (bytes[0] === 3 && text) {
			const status = JSON.parse(text) as {
				status?: string;
				message?: string;
				details?: { causes?: { reason?: string; message?: string }[] };
			};
			if (status.status === "Success") code = 0;
			else {
				const exit = status.details?.causes?.find((c) => c.reason === "ExitCode");
				code = exit ? Number(exit.message) : 100;
				if (!exit) console.error(`refused: ${status.message ?? text}`);
			}
		}
	};
	ws.onerror = (event: Event) =>
		console.error(`refused: ${(event as ErrorEvent).message ?? "the upgrade failed"}`);
	ws.onclose = () => resolve();
});
await done;
process.exit(code);
