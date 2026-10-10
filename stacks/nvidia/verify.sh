# shellcheck shell=bash
# Verify checks for stacks/nvidia: gpu-operator, driver, toolkit, device
# plugin and the GPU tenants (docs/runbooks/verify-jobs.md; software-currency
# design, Verification contract, GPU row).
VERIFY_GROUP="gpu"
VERIFY_NAMESPACES="nvidia"
VERIFY_ALERTNAMES="^(GPU.*|Nvidia.*|NVIDIA.*|DCGM.*)$"
# The MIG manager and MPS control daemon DaemonSets schedule on no node (T4,
# no MIG/MPS), which the floor already treats as converged.

GPU_NODE=k8s-node1

_allocatable() {
  local a
  a=$(kubectl get node "$GPU_NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  echo "$GPU_NODE allocatable nvidia.com/gpu=$a"
  [ "$a" = 100 ]
}

_cluster_policy() {
  local j
  j=$(kubectl get clusterpolicies.nvidia.com cluster-policy -o json) || return 1
  jq -c '{state: .status.state, devicePluginConfig: .spec.devicePlugin.config}' <<<"$j"
  [ "$(jq -r '.status.state' <<<"$j")" = ready ] &&
    [ "$(jq -r '.spec.devicePlugin.config.name' <<<"$j")" = time-slicing-config ] &&
    [ "$(jq -r '.spec.devicePlugin.config.default' <<<"$j")" = any ]
}

_validator() {
  local j
  j=$(kubectl get pods -n nvidia -l app=nvidia-operator-validator -o json) || return 1
  jq -r '.items[0] | "\(.metadata.name) phase=\(.status.phase) " + ([.status.initContainerStatuses[] | "\(.name)=\(.state.terminated.exitCode // "running")"] | join(" "))' <<<"$j"
  [ "$(jq -r '[.items[0].status.initContainerStatuses[] | select(.state.terminated.exitCode != 0)] | length' <<<"$j")" = 0 ] &&
    [ "$(jq -r '.items[0].status.phase' <<<"$j")" = Running ]
}

_smi_vectoradd() {
  run_pod gpu-smi nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0 \
    'nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total --format=csv,noheader && /cuda-samples/vectorAdd' \
    gpu=1 timeout=300 memory=128Mi
}

_gpu_pods_running() {
  local out
  out=$(kubectl get pods -A -o json | jq -r '
    [.items[] | select([.spec.containers[].resources.limits["nvidia.com/gpu"]? // empty] | length > 0)
      | select(.metadata.labels["app.kubernetes.io/managed-by"] != "verify")
      | {n: "\(.metadata.namespace)/\(.metadata.name)", p: .status.phase}] as $g
    | [$g[] | select(.p != "Running" and .p != "Succeeded") | "\(.n)=\(.p)"] as $bad
    | "GPU pods=\($g|length) not running=\($bad)", (if ($bad|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_llama_swap() {
  local L=http://llama-swap.llama-cpp.svc.cluster.local:8080 model out
  # Use the model already loaded when there is one, so the check does not
  # swap the T4's VRAM; otherwise the first text model.
  model=$(curl -sS --max-time 10 "$L/running" | jq -r '[.running[]? | select(.state=="ready") | .model][0] // empty')
  [ -n "$model" ] || model=$(curl -sS --max-time 10 "$L/v1/models" | jq -r '[.data[].id | select(test("vl") | not)][0]')
  out=$(curl -sS --max-time 240 "$L/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word ok.\"}],\"max_tokens\":8,\"temperature\":0}")
  echo "model=$model reply=$(jq -r '.choices[0].message.content // .error // empty' <<<"$out" | head -c 80) tokens=$(jq -r '.usage.completion_tokens // empty' <<<"$out")"
  [ -n "$(jq -r '.choices[0].message.content // empty' <<<"$out")" ]
}

_immich_ml() {
  local out
  out=$(curl -sS --max-time 120 -F 'entries={"clip":{"textual":{"modelName":"ViT-B-16-SigLIP2__webli"}}}' -F 'text=verify probe' \
    http://immich-machine-learning.immich.svc.cluster.local:3003/predict)
  echo "immich ML predict: $(printf '%s' "$out" | head -c 100)"
  grep -q '"clip"' <<<"$out"
}

_frigate() {
  local out
  out=$(curl -sS --max-time 20 http://frigate.frigate.svc.cluster.local/api/stats)
  jq -c '.detectors | to_entries | map({(.key): .value.inference_speed}) | add' <<<"$out"
  # Every detector reports an inference speed between 0 and 500 ms.
  [ "$(jq '[.detectors[] | select(.inference_speed > 0 and .inference_speed < 500)] | length' <<<"$out")" -ge 1 ] &&
    [ "$(jq '[.detectors[] | select(.inference_speed <= 0 or .inference_speed >= 500)] | length' <<<"$out")" -eq 0 ]
}

verify_component() {
  check "nvidia.com/gpu allocatable is 100 on $GPU_NODE" retry 600 30 _allocatable
  check "ClusterPolicy ready with the time-slicing config" retry 600 30 _cluster_policy
  check "driver DaemonSet converged" retry 300 10 workload_ready nvidia daemonset/nvidia-driver-daemonset
  check "device plugin converged" retry 300 10 workload_ready nvidia daemonset/nvidia-device-plugin-daemonset
  check "DCGM exporter converged" retry 300 10 workload_ready nvidia daemonset/nvidia-dcgm-exporter
  check "operator validator: driver, toolkit, CUDA and plugin validations passed" retry 600 30 _validator
  check "test pod runs nvidia-smi and CUDA vectorAdd on one slot" _smi_vectoradd
  check "every GPU pod in the cluster is running" _gpu_pods_running
  check "llama-swap answers a chat completion" _llama_swap
  check "Immich ML runs a CLIP inference" _immich_ml
  check "Frigate detectors report inference speed" _frigate
  check "DCGM metrics are fresh" expect_prom 'max(time() - timestamp(nvidia_tesla_t4_DCGM_FI_DEV_GPU_TEMP))' -lt 180
  check "nvidia and gpu-pod-memory exporters up" expect_prom 'min(up{job=~"nvidia|gpu-pod-memory"})' -eq 1
  check "GPUAllocatableBelowExpected not firing" expect_alert_inactive '^GPUAllocatableBelowExpected$'
}
