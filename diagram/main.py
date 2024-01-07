from unicodedata import name
from diagrams import Diagram, Cluster, Edge, Node
from diagrams.generic.compute import Rack
from diagrams.aws.compute import EC2
from diagrams.aws.database import RDS
from diagrams.k8s.network import Service, Ingress
from diagrams.k8s.compute import Pod
from diagrams.aws.network import ELB
from diagrams.onprem.network import Nginx, Pfsense
from diagrams.generic.network import Firewall, Router, Switch, VPN
from diagrams.generic.storage import Storage
from diagrams.generic.os import Windows, Raspbian, IOS
from diagrams.generic.device import Mobile
from diagrams.onprem.client import Client, Users
from diagrams.aws.iot import IotCamera, IotAnalyticsChannel
from kubernetes import client, config

vpn_clients: dict[str, Node] = {}
# namespaces_to_visualize = {
#     "website", "vaultwarden", "uptime", "technitium", "reverse-proxy",
#     "oauth2", "monitoring", "mailserver", "kms", "immich", "headscale",
#     "frigate", "f1-stream", "excalidraw", "dashy", "calibre", "audiobookshelf"
# }
namespaces_to_not_visualize = {
    "ytdlp", "wireguard", "webhook-handler", "url", "travel-blog", "registry",
    "redis", "openid-help-page", "localai", "kubernetes-dashboard",
    "headscale", "hackmd", "finance-app", "drone", "dbaas", "crowdsec",
    "cloudflared", "city-guesser"
}
# docs for lib - https://diagrams.mingrammer.com/docs/nodes/k8s


def border_router(
    name: str,
    include_vpn_client: bool = False,
) -> tuple[Firewall, Router]:
    with Cluster(name):
        tp_link_fw = Firewall()
        tp_link_router = Router()
        tp_link_fw >> tp_link_router
        if include_vpn_client:
            vpn_client = VPN(f"{name} Tailscale Client")
            vpn_clients[name] = vpn_client
        return tp_link_fw, tp_link_router


def sofia():
    with Cluster("Sofia"):
        _, tp_link_router = border_router("Border Router")
        ext_switch = Switch('Extension Switch')
        tp_link_router >> ext_switch
        with Cluster('R730'):
            with Cluster("Pfsense"):
                pfsense = Pfsense('Firewall')
                vpn_client = VPN("Pfsense Tailscale Client")
                vpn_clients["pfsense"] = vpn_client

            with Cluster('Kubernetes Network'):
                k8s_switch = Switch()

                config.load_kube_config()
                v1 = client.CoreV1Api()
                network_api = client.NetworkingV1Api()
                for namespace in v1.list_namespace(watch=False).items:
                    namespace_name = namespace.metadata.name
                    # if namespace_name not in namespaces_to_visualize:
                    #     continue
                    if namespace_name in namespaces_to_not_visualize:
                        continue
                    with Cluster(namespace_name):
                        for ingress in network_api.list_namespaced_ingress(
                                namespace_name).items:
                            # for k8s_svc in v1.list_namespaced_service(
                            #         namespace_name).items:
                            ingress = Ingress(ingress.spec.rules[0].host)
                            # service = Service(k8s_svc.metadata.name)
                            # k8s_switch >> service
                            k8s_switch >> ingress

                pfsense >> k8s_switch
            with Cluster('Management Network'):
                mgt_switch = Switch()
                # Truenas
                truenas = Storage("Truenas")
                # pxe server
                pxe_server = Rack("PXE Server")
                # HA
                home_assistant = Rack("Home Assistant")
                with Cluster("Devvm"):
                    devvm = Rack("Devvm")
                    devvm_vpn_client = VPN("Tailscale Client")
                    vpn_clients["devvm"] = devvm_vpn_client

                mgt_switch >> truenas
                mgt_switch >> pxe_server
                mgt_switch >> home_assistant
                mgt_switch >> devvm

                pfsense >> mgt_switch

            windows10 = Windows("Windows 10 Server")
            tp_link_router >> windows10

            ext_switch >> pfsense

        nas = Storage('Synology NAS')
        tp_link_router >> nas


def london():
    with Cluster("London"):
        _, openwrt = border_router("London OpenWRT", include_vpn_client=True)
        rpi = Raspbian()
        # client = Mobile()
        # ios_client = IOS()
        ip_cam = IotCamera("IP Camera")
        users = Users()

        openwrt >> rpi
        # openwrt >> client
        # openwrt >> ios_client
        openwrt >> users
        rpi >> Edge() << ip_cam


def valchedrym():
    with Cluster("Valchedrym"):
        _, openwrt = border_router("Valchedrym OpenWRT",
                                   include_vpn_client=True)

        users = Users()
        ip_cam = IotCamera("Surveillance System")
        alarm_system = IotAnalyticsChannel("Alarm System")

        openwrt >> users
        openwrt >> ip_cam
        openwrt >> alarm_system


def mladost3():
    with Cluster("Mladost 3"):
        _, tp_link = border_router("Mladost 3 Router    ")
        laptop = Windows()
        tp_link >> laptop


def outer_infra():
    with Diagram("Home Infra", show=False, outformat="png", direction="LR"):
        sofia()
        london()
        valchedrym()
        mladost3()
        with Cluster("Mobile VPN Clients"):
            mobile_vpn_clients = VPN()
            vpn_clients["mobile vpn users"] = mobile_vpn_clients
            mobile_vpn_users = Users("headscale.viktorbarzin.me/manager")
            mobile_vpn_clients >> mobile_vpn_users
        # link all vpn clients
        existing_links = set()
        for vpn_client in vpn_clients.values():
            for other_vpn_client in vpn_clients.values():
                if other_vpn_client == vpn_client:
                    continue
                key = vpn_client.label + other_vpn_client.label
                reverse_key = other_vpn_client.label + vpn_client.label
                if key in existing_links or reverse_key in existing_links:
                    continue
                vpn_client >> Edge(color="darkgreen") << other_vpn_client
                existing_links.add(key)


def k8s_network():
    with Diagram("Kubernetes Network",
                 show=False,
                 outformat="png",
                 direction="LR"):
        with Cluster("Kubernetes Network"):
            k8s_switch = Switch()
            config.load_kube_config()
            v1 = client.CoreV1Api()
            network_api = client.NetworkingV1Api()
            for namespace in v1.list_namespace(watch=False).items:
                namespace_name = namespace.metadata.name
                # if namespace_name not in namespaces_to_visualize:
                #     continue
                if namespace_name in namespaces_to_not_visualize or namespace_name == "monitoring":
                    continue
                with Cluster(namespace_name):
                    for ingress in network_api.list_namespaced_ingress(
                            namespace_name).items:
                        ing = Ingress(ingress.spec.rules[0].host)
                        rule = ingress.spec.rules[0]
                        # for rule in ingress.spec.rules:
                        path = rule.http.paths[0]
                        # for path in rule.http.paths:
                        k8s_svc = path.backend.service
                        svc = Service(f"{k8s_svc.name}:{k8s_svc.port.number}")
                        ing >> svc
                        pods = v1.list_namespaced_pod(namespace_name)
                        for k8s_pod in pods.items:
                            if k8s_pod.status.phase != "Running":
                                continue
                            pod = Pod(k8s_pod.metadata.name)
                            svc >> pod
                        # service = Service(k8s_svc.metadata.name)
                        # k8s_switch >> service
                        k8s_switch >> ing


if __name__ == '__main__':
    outer_infra()
    k8s_network()
