import asyncio
import click
import logging
import time
from typing import List, Union, Optional
from kubernetes_asyncio import client, config
from kubernetes_asyncio.client.api_client import ApiClient

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)


async def wait_for_healthy(
    api_instance: client.AppsV1Api,
    resource_type: str,
    namespace: str,
    name: str,
    target_replicas: int,
    timeout: int = 300,
) -> None:
    start_time = time.time()
    logger.info(
        f"Waiting for {resource_type} {name} to reach {target_replicas} replicas..."
    )

    while True:
        if time.time() - start_time > timeout:
            logger.error(f"❌ Timeout reached for {resource_type} {name}")
            return

        try:
            if resource_type.lower() == "deployment":
                res = await api_instance.read_namespaced_deployment_status(
                    name, namespace
                )
                ready = res.status.ready_replicas or 0
                updated = res.status.updated_replicas or 0
                if ready == target_replicas and updated == target_replicas:
                    break
            else:  # StatefulSet
                res = await api_instance.read_namespaced_stateful_set_status(
                    name, namespace
                )
                ready = res.status.ready_replicas or 0
                if ready == target_replicas:
                    break

        except Exception as e:
            logger.debug(f"Retrying status check for {name}: {e}")

        await asyncio.sleep(5)

    logger.info(f"✅ {resource_type} {name} is now healthy.")


async def wait_for_zero(
    api: client.AppsV1Api, kind: str, ns: str, name: str, timeout: int
) -> tuple[str, str]:
    start_time = asyncio.get_event_loop().time()
    while (asyncio.get_event_loop().time() - start_time) < timeout:
        try:
            res = await (
                api.read_namespaced_deployment_status(name, ns)
                if kind.lower() == "deployment"
                else api.read_namespaced_stateful_set_status(name, ns)
            )
            if (res.status.ready_replicas or 0) == 0:
                return ns, name
        except Exception:
            return ns, name  # Assume gone if error
        await asyncio.sleep(3)
    logger.error(f"Timeout: {kind} {ns}/{name} still has running pods.")
    return ns, name


async def scale_resource(
    api_instance: client.AppsV1Api,
    resource_type: str,
    namespace: str,
    name: str,
    replicas: int,
) -> None:
    body = {"spec": {"replicas": replicas}}
    try:
        if resource_type.lower() == "deployment":
            await api_instance.patch_namespaced_deployment_scale(name, namespace, body)
        else:
            await api_instance.patch_namespaced_stateful_set_scale(
                name, namespace, body
            )
    except Exception as e:
        logger.error(f"Failed to scale {resource_type} {name}: {e}")


async def run_stop_tier(
    api_v1: client.AppsV1Api, label: str, output_file: str, timeout: int
) -> None:
    """Processes a single label tier: saves, scales to 0, and waits."""
    excluded_ns = ["kube-system", "kube-public", "kube-node-lease"]

    # 1. Discover
    targets = [
        ("Deployment", api_v1.list_deployment_for_all_namespaces),
        ("StatefulSet", api_v1.list_stateful_set_for_all_namespaces),
    ]

    tier_resources = []
    for kind, list_func in targets:
        resp = await list_func(label_selector=label)
        tier_resources.extend(
            [
                (kind, item)
                for item in resp.items
                if item.metadata.namespace not in excluded_ns
            ]
        )

    if not tier_resources:
        logger.warning(f"No resources found for label: {label}")
        return

    # 2. Save & Scale
    active_jobs: set[tuple[str, str]] = set()
    wait_tasks = []

    # Append to file so we don't overwrite previous tiers
    with open(output_file, "a") as f:
        for kind, item in tier_resources:
            ns, name = item.metadata.namespace, item.metadata.name
            reps = item.spec.replicas or 0
            f.write(f"{kind} {ns} {name} {reps}\n")
            active_jobs.add((ns, name))

            await scale_resource(api_v1, kind, ns, name, 0)
            wait_tasks.append(wait_for_zero(api_v1, kind, ns, name, timeout))

    # 3. Wait for this tier to finish before moving to next
    logger.info(f"Tier [{label}]: Waiting for {len(active_jobs)} resources to stop...")
    for coro in asyncio.as_completed(wait_tasks):
        finished_ns, finished_name = await coro
        active_jobs.discard((finished_ns, finished_name))
        if active_jobs:
            remaining_ns = sorted({ns for ns, name in active_jobs})
            logger.info(
                f"[{label}] Pending: {len(active_jobs)} | Namespaces: {', '.join(remaining_ns)}"
            )

    logger.info(f"✅ Tier [{label}] successfully shut down.")


@click.group()
def cli():
    pass


@cli.command()
@click.argument("labels", nargs=-1, required=True)
@click.option("--output", "-o", default="resources.txt", help="Output state file")
@click.option("--timeout", "-t", default=3600)
def stop(labels: List[str], output: str, timeout: int):
    """Stop tiers sequentially. Usage: stop 'app=web' 'app=db'"""

    async def main():
        await config.load_kube_config()
        # Clear/Create file at start
        open(output, "w").close()

        async with ApiClient() as api_client:
            api_v1 = client.AppsV1Api(api_client)
            for label in labels:
                logger.info(f"🚀 Processing Shutdown Tier: {label}")
                await run_stop_tier(api_v1, label, output, timeout)
        logger.info("🏁 Sequence complete. Cluster is gracefully stopped.")

    asyncio.run(main())


@cli.command()
@click.argument("labels", nargs=-1, required=True)
@click.option("--file", "-f", default="resources.txt")
@click.option("--timeout", "-t", default=3600, help="Seconds to wait per resource")
def start(labels: List[str], file: str, timeout: int):
    asyncio.run(run_start_sequence(labels, file, timeout))


async def run_start_sequence(labels: List[str], file_path: str, timeout: int) -> None:
    await config.load_kube_config()

    async with ApiClient() as api_client:
        apps_v1 = client.AppsV1Api(api_client)

        # 1. Load the entire snapshot into memory for filtering
        try:
            with open(file_path, "r") as f:
                # Format: Kind Namespace Name Replicas
                snapshot_lines = [line.strip().split() for line in f if line.strip()]
        except FileNotFoundError:
            logger.error(f"Snapshot file {file_path} not found.")
            return

        # 2. Iterate through labels in the order provided
        for label in labels:
            logger.info(f"🚀 Starting Tier: {label}")

            # Find resources in this tier by querying K8s for the label
            # then matching against our snapshot file data
            tier_resources = await get_resources_by_label(apps_v1, label)

            # Cross-reference: Only start things that are in BOTH the K8s label query AND our file
            # This ensures we restore them to the CORRECT previous replica count
            to_restore = []
            tier_keys = {(r["ns"], r["name"]) for r in tier_resources}

            for kind, ns, name, reps in snapshot_lines:
                if (ns, name) in tier_keys:
                    to_restore.append((kind, ns, name, int(reps)))

            if not to_restore:
                logger.warning(f"No resources found in snapshot for tier: {label}")
                continue

            # 3. Scale and Wait for this specific tier
            await process_start_tier(apps_v1, to_restore, timeout, label)

        logger.info("🏁 All tiers started successfully.")


async def get_resources_by_label(api: client.AppsV1Api, label: str) -> List[dict]:
    """Helper to find what currently exists in the cluster with this label."""
    targets = [
        api.list_deployment_for_all_namespaces,
        api.list_stateful_set_for_all_namespaces,
    ]
    found = []
    for list_func in targets:
        resp = await list_func(label_selector=label)
        for item in resp.items:
            found.append({"ns": item.metadata.namespace, "name": item.metadata.name})
    return found


async def process_start_tier(
    api: client.AppsV1Api, resources: list, timeout: int, label: str
):
    active_jobs = set()
    scale_tasks = []
    wait_tasks = []

    # Wrapper to track which job finishes
    async def tracked_wait(kind, ns, name, target, t_out):
        await wait_for_healthy(api, kind, ns, name, target, t_out)
        return (ns, name)

    for kind, ns, name, reps in resources:
        active_jobs.add((ns, name))
        scale_tasks.append(scale_resource(api, kind, ns, name, reps))
        wait_tasks.append(tracked_wait(kind, ns, name, reps, timeout))

    # Trigger all scales for this tier
    await asyncio.gather(*scale_tasks)

    # Monitor health
    for coro in asyncio.as_completed(wait_tasks):
        finished_ns, finished_name = await coro
        active_jobs.discard((finished_ns, finished_name))

        if active_jobs:
            remaining_ns = sorted({ns for ns, name in active_jobs})
            logger.info(
                f"[{label}] Pending Health: {len(active_jobs)} | Namespaces: {', '.join(remaining_ns)}"
            )

    logger.info(f"✅ Tier [{label}] is healthy.")


if __name__ == "__main__":
    cli()
