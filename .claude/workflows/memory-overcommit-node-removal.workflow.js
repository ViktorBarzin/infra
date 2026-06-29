export const meta = {
  name: 'memory-overcommit-node-removal',
  description: 'Read-only: assess PVE host + k8s memory overcommit, right-size deployment REQUESTS (scheduling) and LIMITS (OOM) separately from 30d usage, then test whether one worker node can be removed while preserving N-1 by BOTH a physical-usage and a scheduling-request model. Emits a gated plan.',
  phases: [
    { title: 'Gather' },
    { title: 'Model' },
    { title: 'Verify' },
  ],
}

// ---------- confirmed read-only access paths ----------
const SSH = "ssh -o BatchMode=yes -o ConnectTimeout=8 root@192.168.1.127";
const PROM = "https://prometheus-query.viktorbarzin.lan/api/v1/query";
const G = (mib) => (mib == null ? "?" : (mib / 1024).toFixed(1) + "Gi");

// ---------- schema helpers ----------
const num = { type: "number" }, str = { type: "string" }, bool = { type: "boolean" };
const arr = (items) => ({ type: "array", items });
const obj = (props) => ({ type: "object", additionalProperties: false, required: Object.keys(props), properties: props });

const HOST = obj({
  host_total_mib: num, host_used_mib: num, host_free_mib: num, host_available_mib: num,
  swap_total_mib: num, swap_used_mib: num, ksm_saved_mib: num,
  vms: arr(obj({ vmid: num, name: str, configured_mib: num, balloon_mib: num, rss_mib: num, is_k8s_node: bool })),
  sum_vm_configured_mib: num, sum_vm_rss_mib: num, notes: str,
});

const K8S = obj({
  nodes: arr(obj({
    name: str, role: str, is_gpu: bool, is_control_plane: bool, gpu_tainted: bool, schedulable: bool,
    capacity_mib: num, allocatable_mib: num, requests_mib: num, ds_requests_mib: num, limits_mib: num, usage_now_mib: num, peak_30d_mib: num, pod_count: num,
  })),
  cluster_allocatable_mib: num, cluster_requests_mib: num, cluster_usage_now_mib: num, cluster_peak_30d_mib: num, notes: str,
});

// NOTE the v2 split: requests are sized for SCHEDULING (cover normal load, can shrink below current),
// limits are sized for OOM SAFETY (cover peak). They are DIFFERENT knobs and must not be conflated.
const USAGE = obj({
  totals: obj({
    sum_current_requests_mib: num, sum_recommended_requests_mib: num, net_request_reclaim_mib: num,
    reschedulable_request_recommended_mib: num, ds_request_recommended_per_node_mib: num, gpu_request_recommended_mib: num,
    largest_single_request_mib: num, count_request_shrink: num, count_limit_raise_oom: num,
  }),
  request_shrinks: arr(obj({ namespace: str, name: str, kind: str, replicas: num, current_request_mib: num, p95_30d_mib: num, recommended_request_mib: num, delta_mib: num, rationale: str })),
  limit_raises_oom: arr(obj({ namespace: str, name: str, container: str, current_limit_mib: num, peak_max_30d_mib: num, recommended_limit_mib: num, risk: str })),
  spiky_periodic: arr(obj({ namespace: str, name: str, note: str })),
  method_notes: str,
});

const TOPO = obj({
  nodes: arr(obj({ name: str, sticky_pods: arr(str), local_pv_count: num, volumeattachments: num, cnpg_primary: bool, gpu_workloads: bool, evac_difficulty: str, evac_notes: str })),
  spofs: arr(obj({ namespace: str, name: str, replicas: num, has_pdb: bool, issue: str })),
  antiaffinity_risks: arr(str),
  csi_pinning_note: str,
  priority_classes_note: str,
  notes: str,
});

const VERDICT = obj({ refuted: bool, confidence: str, reasoning: str, corrections: arr(str) });

// ---------- prompts ----------
const HOST_PROMPT = `Read-only PVE host memory audit. SSH (key-based): ${SSH} '<cmd>'  (host 'pve', the Proxmox r730 at 192.168.1.127). Read-only ONLY; NEVER a state-changing qm/pvesh/ha-manager command.
- 'free -m' -> host_total/used/free/available_mib + swap_total/swap_used_mib.
- KSM: cat /sys/kernel/mm/ksm/pages_sharing ; ksm_saved_mib = pages_sharing*4096/1048576.
- 'qm list'; for each running VM 'qm config <vmid>' -> memory (configured_mib), balloon (balloon_mib; if balloon==memory or balloon==0 ballooning is effectively OFF -> host RSS pins near configured = the headroom RATCHET).
- Per-VM host RSS: read /var/run/qemu-server/<vmid>.pid then 'ps -o rss= -p <pid>' (KiB->MiB).
- is_k8s_node = VMs named k8s-*.
Return per-VM rows + sum_vm_configured_mib + sum_vm_rss_mib over ALL RUNNING VMs. notes: overcommit ratio, swap pressure, ballooning state.`;

const K8S_PROMPT = `Read-only Kubernetes node-capacity audit. kubectl read access confirmed. For every node (k8s-master + k8s-node1..6):
- capacity_mib & allocatable_mib from 'kubectl get node <n> -o json' (Ki->MiB).
- is_control_plane (node-role.kubernetes.io/control-plane), is_gpu (k8s-node1; nvidia.com/gpu in capacity), gpu_tainted (a NoSchedule taint general pods would NOT tolerate), schedulable.
- requests_mib, limits_mib, ds_requests_mib (DaemonSet-owned pods only), usage_now_mib, pod_count.
  Prefer Prometheus (curl -sk -G '${PROM}' --data-urlencode 'query=<q>'):
    sum by (node)(kube_pod_container_resource_requests{resource="memory"})    [these metrics HAVE a node label]
    usage_now: cAdvisor container_memory_working_set_bytes has NO node label - join: sum by (node)(container_memory_working_set_bytes{container!="",container!="POD"} * on(namespace,pod) group_left(node) kube_pod_info)
- peak_30d_mib per node: max_over_time of that joined per-node sum over [30d:5m] (best effort; if the join is flaky leave 0 and rely on cluster figure).
ALSO return cluster-wide:
- cluster_allocatable_mib, cluster_requests_mib, cluster_usage_now_mib.
- cluster_peak_30d_mib = max_over_time(sum(container_memory_working_set_bytes{container!="",container!="POD"})[30d:5m]) /1024/1024  (this is the PHYSICAL reliability bedrock - the highest the whole cluster ever simultaneously used in 30d).
notes: host-vs-k8s overcommit contrast (requests vs allocatable vs actual usage).`;

const USAGE_PROMPT = `Read-only memory RIGHT-SIZING from 30-day usage. CRITICAL: requests and limits are DIFFERENT knobs - size them separately. Do NOT set requests to peak (that is what a flawed earlier run did; it manufactured a false capacity shortfall).
- REQUEST (scheduling reservation, drives bin-packing & node-removal feasibility): size to cover NORMAL operation = recommended_request_mib = ceil(max(p95_30d * 1.15, 64)). This SHRINKS the many over-provisioned requests toward real usage. requests should sit BELOW limits (Burstable). Be moderately conservative for stateful/db/critical infra (mysql, postgres/CNPG, redis, vault, prometheus, mailserver): use p99 instead of p95.
- LIMIT (OOM ceiling): recommended_limit_mib = ceil(peak_max_30d * 1.25). FLAG any container whose peak_max_30d >= 95% of current limit as an OOM risk (limit_raises_oom) - these are real reliability bugs to fix REGARDLESS of node removal.

Sources: kubectl (current requests/limits/replicas for Deployments/StatefulSets/DaemonSets, all namespaces); Prometheus (curl -sk -G '${PROM}' --data-urlencode 'query=<q>'):
  p95: quantile_over_time(0.95, container_memory_working_set_bytes{container!="",container!="POD"}[30d])
  p99: quantile_over_time(0.99, ...[30d])
  peak: max_over_time(...[30d])
  Aggregate by (namespace,pod,container), map pod->workload (strip hash suffixes), take MAX across a workload's pods as per-replica value.

Splits for the N-1 model (use the REQUEST recommendation; multiply per-replica by replicas):
- reschedulable_request_recommended_mib = SUM recommended_request of Deployment+StatefulSet pods that are NON-GPU and schedulable on general workers (everything that must reschedule if a worker is removed).
- ds_request_recommended_per_node_mib = SUM recommended_request of DaemonSet containers (one set per node).
- gpu_request_recommended_mib = SUM recommended_request of workloads pinned to GPU node k8s-node1 (REAL value; do not inflate).
- largest_single_request_mib = largest single recommended per-replica request among reschedulable.
Return totals (sum_current_requests_mib, sum_recommended_requests_mib, net_request_reclaim_mib = sum of POSITIVE request deltas i.e. shrinks, the splits, count_request_shrink, count_limit_raise_oom), request_shrinks (top ~30 by delta), limit_raises_oom (every OOM-tight container), spiky_periodic (mailserver/immich-ml/backups/dumps/postiz). NEVER mutate.`;

const TOPO_PROMPT = `Read-only reliability-topology audit: which worker is safest to remove? Candidates: k8s-node2..node6 (NOT master, NOT GPU node1). For each worker (k8s-node1..6): sticky_pods (StatefulSet members; pods with local/hostPath PVCs; single-replica critical), local_pv_count, volumeattachments, cnpg_primary (CNPG 'pg-cluster' PRIMARY here? check pod role labels), gpu_workloads, evac_difficulty (easy|medium|hard)+evac_notes.
Cluster-wide: spofs (1 replica AND no PDB); antiaffinity_risks (hard podAntiAffinity / topologySpread DoNotSchedule that becomes UNSATISFIABLE at one fewer worker - check replica counts vs surviving distinct hosts); csi_pinning_note (do Proxmox-CSI PVs pin to a node, or share one host-level topology so they reattach anywhere? check volumeHandle / topology zone/region on the PVs - this decides whether removal STRANDS data); priority_classes_note. NEVER mutate.`;

// ============================================================
phase('Gather');
log('Gather (read-only): PVE host memory, k8s capacity + cluster 30d peak, request/limit right-sizing, reliability topology');
const [host, k8s, usage, topo] = await parallel([
  () => agent(HOST_PROMPT, { label: 'gather:pve-host', phase: 'Gather', schema: HOST }),
  () => agent(K8S_PROMPT, { label: 'gather:k8s-capacity', phase: 'Gather', schema: K8S }),
  () => agent(USAGE_PROMPT, { label: 'gather:rightsize', phase: 'Gather', schema: USAGE }),
  () => agent(TOPO_PROMPT, { label: 'gather:reliability', phase: 'Gather', schema: TOPO }),
]);
if (!k8s || !usage) return { error: 'Critical gather agent failed (k8s/usage).', host, k8s, usage, topo };

// ============================================================
phase('Model');
const T = usage.totals;
const workers = k8s.nodes.filter((n) => !n.is_control_plane);
const generalPool = workers.filter((n) => !n.gpu_tainted);            // general pods can land here (incl. GPU node if not tainted)
const candidates = workers.filter((n) => !n.is_gpu && !n.is_control_plane); // node2..node6
const clusterPeak = k8s.cluster_peak_30d_mib || 0;

const freeGeneral = (n) => n.allocatable_mib - (T.ds_request_recommended_per_node_mib || 0) - (n.is_gpu ? (T.gpu_request_recommended_mib || 0) : 0);

function evalRemove(removeName) {
  const pool = generalPool.filter((n) => n.name !== removeName);
  // --- scheduling N-1 (realistic requests): fit reschedulable load even if the largest survivor then fails ---
  const frees = pool.map(freeGeneral);
  const schedCap = frees.reduce((a, b) => a + b, 0) - (frees.length ? Math.max(...frees) : 0);
  const schedNeed = T.reschedulable_request_recommended_mib;
  const schedMargin = schedCap - schedNeed;
  // --- physical N-1 (actual peak usage): cluster 30d peak must fit on survivors after losing the largest too ---
  const survAlloc = pool.map((n) => n.allocatable_mib);
  const physCap = survAlloc.reduce((a, b) => a + b, 0) - (survAlloc.length ? Math.max(...survAlloc) : 0);
  const physMargin = physCap - clusterPeak;
  const t = topo && topo.nodes ? topo.nodes.find((n) => n.name === removeName) : null;
  return {
    removeName, pool: pool.map((n) => n.name),
    sched_capacityN1_mib: Math.round(schedCap), sched_need_mib: Math.round(schedNeed), sched_margin_mib: Math.round(schedMargin), sched_pass: schedMargin >= 0,
    phys_capacityN1_mib: Math.round(physCap), cluster_peak_mib: Math.round(clusterPeak), phys_margin_mib: Math.round(physMargin), phys_pass: physMargin >= 0,
    pass: schedMargin >= 0 && physMargin >= 0,
    host_freed_mib: hostFreedFor(removeName),
    evac_difficulty: t ? t.evac_difficulty : 'unknown', cnpg_primary: t ? t.cnpg_primary : false, sticky_pods: t ? t.sticky_pods : [],
  };
}
function hostFreedFor(nodeName) {
  if (host && host.vms) {
    const s = nodeName.replace('k8s-', '');
    const vm = host.vms.find((v) => v.name === nodeName || (v.name && v.name.includes(s)));
    if (vm) return vm.configured_mib;
  }
  const n = k8s.nodes.find((x) => x.name === nodeName);
  return n ? n.capacity_mib : 0;
}

const evalCandidates = candidates.map((c) => evalRemove(c.name));
const diffRank = { easy: 0, medium: 1, hard: 2, unknown: 3 };
const passing = evalCandidates.filter((c) => c.pass && !c.cnpg_primary)
  .sort((a, b) => (diffRank[a.evac_difficulty] - diffRank[b.evac_difficulty]) || (b.phys_margin_mib - a.phys_margin_mib));
const best = passing[0] || null;

const hostOvercommit = host ? { sum_vm_configured_mib: host.sum_vm_configured_mib, host_total_mib: host.host_total_mib, ratio: +(host.sum_vm_configured_mib / host.host_total_mib).toFixed(3), free_mib: host.host_free_mib, available_mib: host.host_available_mib, swap_used_mib: host.swap_used_mib, swap_total_mib: host.swap_total_mib, ksm_saved_mib: host.ksm_saved_mib } : null;
const k8sOvercommit = { cluster_requests_mib: k8s.cluster_requests_mib, cluster_allocatable_mib: k8s.cluster_allocatable_mib, cluster_usage_now_mib: k8s.cluster_usage_now_mib, cluster_peak_30d_mib: clusterPeak, request_ratio: +(k8s.cluster_requests_mib / k8s.cluster_allocatable_mib).toFixed(3), usage_ratio: +(clusterPeak / k8s.cluster_allocatable_mib).toFixed(3) };

log(`Host overcommit ${hostOvercommit ? hostOvercommit.ratio : '?'}x (${G(hostOvercommit && hostOvercommit.free_mib)} free, swap ${G(hostOvercommit && hostOvercommit.swap_used_mib)}/${G(hostOvercommit && hostOvercommit.swap_total_mib)})`);
log(`K8s: requests ${G(k8s.cluster_requests_mib)} / 30d-peak-usage ${G(clusterPeak)} / allocatable ${G(k8s.cluster_allocatable_mib)} -> requests are ${(k8s.cluster_requests_mib / clusterPeak).toFixed(2)}x real peak`);
log(`Request right-sizing: ${G(T.net_request_reclaim_mib)} of over-provisioned requests can be trimmed (${T.count_request_shrink} workloads); ${T.count_limit_raise_oom} workloads are OOM-tight on LIMITS (raise regardless).`);
for (const c of evalCandidates) log(`  remove ${c.removeName}: phys-N1 ${c.phys_pass ? 'PASS' : 'FAIL'} (${G(c.phys_margin_mib)}) | sched-N1 ${c.sched_pass ? 'PASS' : 'FAIL'} (${G(c.sched_margin_mib)}) | frees ~${G(c.host_freed_mib)} host | evac ${c.evac_difficulty}${c.cnpg_primary ? ' CNPG-PRIMARY' : ''}`);
log(best ? `Best candidate: ${best.removeName} (phys margin ${G(best.phys_margin_mib)}, frees ~${G(best.host_freed_mib)})` : 'No candidate passes both N-1 tests.');

// ============================================================
phase('Verify');
const headline = best
  ? `${best.removeName} can be removed while preserving N-1: cluster 30d peak usage ${G(clusterPeak)} fits on survivors-minus-one (${G(best.phys_capacityN1_mib)}); after trimming over-provisioned requests, scheduling also fits (${G(best.sched_margin_mib)} margin). Frees ~${G(best.host_freed_mib)} to the PVE host.`
  : `No worker can be removed while preserving N-1 by BOTH physical-usage and scheduling-request models.`;
const verifyData = JSON.stringify({ hostOvercommit, k8sOvercommit, k8s_nodes: k8s.nodes, usage_totals: T, evalCandidates, best, csi_pinning_note: topo ? topo.csi_pinning_note : null, generalPool: generalPool.map((n) => n.name) }, null, 2);
const lenses = [
  { key: 'math', ask: 'Recompute BOTH N-1 models independently. Physical: cluster 30d peak vs (sum survivor allocatable - largest survivor). Scheduling: reschedulable recommended REQUESTS (not limits, not peak) vs (sum survivor freeGeneral - largest). Verify GPU node reserve uses REAL gpu requests, allocatable not capacity, DaemonSets are per-node fixed load. Are pool selection and numbers right?' },
  { key: 'temporal', ask: 'Challenge the 30-DAY peak window and the request shrinks. Could a monthly/quarterly peak exceed cluster_peak_30d (compare a 90d peak)? Are the shrunk REQUESTS safe given each workload keeps a limit above its peak (Burstable)? Name any shrink or any still-tight limit that is reckless.' },
  { key: 'stateful', ask: 'Check the chosen candidate for STRANDED state and drain blockers: CSI PV pinning (do volumes reattach anywhere?), CNPG primary, VolumeAttachment caps, anti-affinity/topologySpread unsatisfiable at one fewer worker, PDBs that block drain (disruptionsAllowed=0). Is removal actually safe, and what drain ORDERING is required?' },
];
const verdicts = (await parallel(lenses.map((l) => () =>
  agent(`Adversarial reviewer. Try to REFUTE:\n"${headline}"\n\nLens: ${l.ask}\n\nData (read-only). Verify LIVE: kubectl, Prometheus (curl -sk -G '${PROM}' --data-urlencode 'query=...'), ${SSH} '<cmd>'.\n\n${verifyData}\n\nDefault refuted=true if evidence does not clearly hold. Give concrete corrections.`,
    { label: `verify:${l.key}`, phase: 'Verify', schema: VERDICT }))
)).filter(Boolean);

return {
  headline,
  hostOvercommit, k8sOvercommit,
  rightsizing: T,
  request_shrinks: usage.request_shrinks,
  limit_raises_oom: usage.limit_raises_oom,
  spiky_periodic: usage.spiky_periodic,
  candidates: evalCandidates,
  recommendation: best,
  k8s_nodes: k8s.nodes,
  host_vms: host ? host.vms : null,
  topo_spofs: topo ? topo.spofs : [],
  topo_nodes: topo ? topo.nodes : [],
  csi_pinning_note: topo ? topo.csi_pinning_note : null,
  antiaffinity_risks: topo ? topo.antiaffinity_risks : [],
  verdicts,
  verdict_summary: `${verdicts.filter((v) => v.refuted).length}/${verdicts.length} reviewers refuted the headline`,
};
