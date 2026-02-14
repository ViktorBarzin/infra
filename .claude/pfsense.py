#!/usr/bin/env python3
"""pfSense CLI tool for managing the firewall via SSH.

Usage:
    python pfsense.py <command> [options]

Commands:
    status              System status overview
    interfaces          List interfaces with IPs and status
    gateways            Show gateway status
    rules [iface]       List firewall rules (optional: filter by interface)
    nat                 List NAT/port forward rules
    aliases             List firewall aliases
    alias <name>        Show alias details (members)
    states              Show state table summary
    states-top [n]      Top N connections by state count (default 10)
    dhcp-leases [iface] Show DHCP leases (optional: filter by interface)
    arp                 Show ARP table
    routes              Show routing table
    services            List services and status
    service <action> <name>  Start/stop/restart a service
    logs [n]            Show last N log lines (default 50)
    logs-filter <text>  Search logs for text
    pfctl <args>        Run arbitrary pfctl command
    php <code>          Run PHP code on pfSense shell
    diag <host>         Ping diagnostic to host
    backup              Download config backup to stdout (XML)
    uptime              Show system uptime
    cpu                 Show CPU usage
    memory              Show memory usage
    disk                Show disk usage
    temp                Show CPU temperature
    pkg-list            List installed packages
    dns-resolve <host>  Resolve hostname via pfSense DNS
    wireguard           Show WireGuard status
    bgp                 Show BGP summary (FRR)
    ospf                Show OSPF neighbors (FRR)
    tailscale           Show Tailscale status
    snort               Show Snort status
    raw <command>       Run arbitrary shell command
"""

import argparse
import json
import subprocess
import sys


PFSENSE_HOST = "admin@10.0.20.1"
SSH_OPTS = ["-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no"]


def ssh(cmd: str, timeout: int = 30) -> str:
    """Execute a command on pfSense via SSH."""
    result = subprocess.run(
        ["ssh"] + SSH_OPTS + [PFSENSE_HOST, cmd],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0 and result.stderr:
        print(f"Error: {result.stderr.strip()}", file=sys.stderr)
    return result.stdout.strip()


def cmd_status(_args):
    print(ssh("""
        echo "=== System ==="
        uname -sr
        echo "Version: $(cat /etc/version)"
        uptime
        echo ""
        echo "=== CPU ==="
        sysctl -n hw.model
        echo "Load: $(sysctl -n vm.loadavg)"
        echo ""
        echo "=== Memory ==="
        php -r '
            $mem = @file_get_contents("/proc/meminfo") ?: "";
            $total = (int)shell_exec("sysctl -n hw.physmem") / 1024 / 1024;
            $free_pages = (int)shell_exec("sysctl -n vm.stats.vm.v_free_count");
            $page_size = (int)shell_exec("sysctl -n hw.pagesize");
            $free = $free_pages * $page_size / 1024 / 1024;
            printf("Total: %.0f MB, Free: %.0f MB, Used: %.0f MB (%.1f%%)\n",
                $total, $free, $total - $free, ($total - $free) / $total * 100);
        '
        echo ""
        echo "=== Disk ==="
        df -h / /var /tmp 2>/dev/null | grep -v "^Filesystem" | awk '{print $6 ": " $3 "/" $1 " (" $5 " used)"}'
        echo ""
        echo "=== States ==="
        pfctl -si 2>/dev/null | grep "current entries"
        echo ""
        echo "=== Temperature ==="
        sysctl -a 2>/dev/null | grep temperature | head -5
    """))


def cmd_interfaces(_args):
    print(ssh("""
        php -r '
            require_once("config.inc");
            require_once("interfaces.inc");
            $cfg = parse_config(true);
            foreach($cfg["interfaces"] as $k => $v) {
                $if = $v["if"] ?? "?";
                $descr = $v["descr"] ?? $k;
                $ip = $v["ipaddr"] ?? "dhcp";
                $subnet = $v["subnet"] ?? "";
                $enabled = isset($v["enable"]) || $k == "wan" || $k == "lan" ? "UP" : "DOWN";
                $gw = $v["gateway"] ?? "-";
                printf("%-8s %-20s %-10s %-18s gw:%-10s %s\n", $k, $descr, $if, $ip . ($subnet ? "/" . $subnet : ""), $gw, $enabled);
            }
        '
    """))


def cmd_gateways(_args):
    print(ssh("pfSsh.php playback gatewaystatus"))


def cmd_rules(args):
    iface_filter = args.interface if hasattr(args, 'interface') and args.interface else ""
    if iface_filter:
        print(ssh(f"pfctl -sr 2>/dev/null | grep -i '{iface_filter}'"))
    else:
        print(ssh("pfctl -sr 2>/dev/null"))


def cmd_nat(_args):
    print(ssh("pfctl -sn 2>/dev/null"))


def cmd_aliases(_args):
    print(ssh("pfctl -sT 2>/dev/null"))


def cmd_alias(args):
    print(ssh(f"pfctl -t {args.name} -T show 2>/dev/null"))


def cmd_states(_args):
    print(ssh("pfctl -si 2>/dev/null"))


def cmd_states_top(args):
    n = args.n if hasattr(args, 'n') and args.n else 10
    print(ssh(f"pfctl -ss 2>/dev/null | awk '{{print $3}}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -{n}"))


def cmd_dhcp_leases(args):
    iface = args.interface if hasattr(args, 'interface') and args.interface else ""
    filter_clause = f'if($l["if"] == "{iface}")' if iface else ""
    print(ssh(f"""
        php -r '
            require_once("config.inc");
            require_once("interfaces.inc");
            $leases = system_get_dhcpleases();
            foreach($leases["lease"] as $l) {{
                {filter_clause}
                printf("%-16s %-18s %-8s %-15s %-10s %s\n",
                    $l["ip"], $l["mac"] ?? "-", $l["act"] ?? "-",
                    $l["hostname"] ?? "-", $l["if"] ?? "-",
                    $l["online"] ?? "-");
            }}
        '
    """))


def cmd_arp(_args):
    print(ssh("arp -an"))


def cmd_routes(_args):
    print(ssh("netstat -rn"))


def cmd_services(_args):
    print(ssh("""
        php -r '
            require_once("config.inc");
            require_once("service-utils.inc");
            $svcs = get_services();
            foreach($svcs as $s) {
                $status = get_service_status($s) ? "RUNNING" : "STOPPED";
                printf("%-30s %s\n", $s["name"], $status);
            }
        '
    """))


def cmd_service(args):
    action = args.action
    name = args.name
    if action not in ("start", "stop", "restart"):
        print(f"Invalid action: {action}. Use start/stop/restart.", file=sys.stderr)
        sys.exit(1)
    print(ssh(f"pfSsh.php playback svc {action} {name}"))


def cmd_logs(args):
    n = args.n if hasattr(args, 'n') and args.n else 50
    print(ssh(f"clog -f /var/log/filter.log 2>/dev/null | tail -{n}"))


def cmd_logs_filter(args):
    print(ssh(f"clog -f /var/log/filter.log 2>/dev/null | grep -i '{args.text}'"))


def cmd_pfctl(args):
    print(ssh(f"pfctl {args.args}"))


def cmd_php(args):
    print(ssh(f"php -r '{args.code}'"))


def cmd_diag(args):
    print(ssh(f"ping -c 4 {args.host}"))


def cmd_backup(_args):
    print(ssh("cat /cf/conf/config.xml"))


def cmd_uptime(_args):
    print(ssh("uptime"))


def cmd_cpu(_args):
    print(ssh("""
        echo "Load: $(sysctl -n vm.loadavg)"
        echo "Model: $(sysctl -n hw.model)"
        echo "Cores: $(sysctl -n hw.ncpu)"
        top -b -d1 2>/dev/null | head -5 || vmstat 1 2 | tail -1
    """))


def cmd_memory(_args):
    print(ssh("""
        php -r '
            $total = (int)shell_exec("sysctl -n hw.physmem") / 1024 / 1024;
            $free_pages = (int)shell_exec("sysctl -n vm.stats.vm.v_free_count");
            $inactive_pages = (int)shell_exec("sysctl -n vm.stats.vm.v_inactive_count");
            $cache_pages = (int)shell_exec("sysctl -n vm.stats.vm.v_cache_count");
            $page_size = (int)shell_exec("sysctl -n hw.pagesize");
            $free = $free_pages * $page_size / 1024 / 1024;
            $inactive = $inactive_pages * $page_size / 1024 / 1024;
            $cache = $cache_pages * $page_size / 1024 / 1024;
            $used = $total - $free - $inactive - $cache;
            printf("Total:    %.0f MB\n", $total);
            printf("Used:     %.0f MB (%.1f%%)\n", $used, $used / $total * 100);
            printf("Free:     %.0f MB\n", $free);
            printf("Inactive: %.0f MB\n", $inactive);
            printf("Cache:    %.0f MB\n", $cache);
        '
    """))


def cmd_disk(_args):
    print(ssh("df -h"))


def cmd_temp(_args):
    print(ssh("sysctl -a 2>/dev/null | grep -i temp"))


def cmd_pkg_list(_args):
    print(ssh("pfSsh.php playback listpkg"))


def cmd_dns_resolve(args):
    print(ssh(f"drill {args.host} @127.0.0.1 2>/dev/null || host {args.host} 127.0.0.1 2>/dev/null || nslookup {args.host} 127.0.0.1"))


def cmd_wireguard(_args):
    print(ssh("wg show 2>/dev/null || echo 'WireGuard not active or wg command not found'"))


def cmd_bgp(_args):
    print(ssh("/usr/local/bin/vtysh -c 'show bgp summary' 2>/dev/null || echo 'FRR/BGP not available'"))


def cmd_ospf(_args):
    print(ssh("/usr/local/bin/vtysh -c 'show ip ospf neighbor' 2>/dev/null || echo 'FRR/OSPF not available'"))


def cmd_tailscale(_args):
    print(ssh("tailscale status 2>/dev/null || echo 'Tailscale not available'"))


def cmd_snort(_args):
    print(ssh("""
        php -r '
            require_once("config.inc");
            require_once("service-utils.inc");
            $svcs = get_services();
            foreach($svcs as $s) {
                if(stripos($s["name"], "snort") !== false) {
                    $status = get_service_status($s) ? "RUNNING" : "STOPPED";
                    printf("%-30s %s\n", $s["name"], $status);
                }
            }
        '
        echo "---Alerts (last 20)---"
        cat /var/log/snort/snort_*/alert 2>/dev/null | tail -20 || echo "No alert logs found"
    """))


def cmd_raw(args):
    print(ssh(args.command))


def main():
    parser = argparse.ArgumentParser(description="pfSense management via SSH")
    sub = parser.add_subparsers(dest="command", help="Command to run")

    sub.add_parser("status", help="System status overview")
    sub.add_parser("interfaces", help="List interfaces")
    sub.add_parser("gateways", help="Show gateway status")

    p = sub.add_parser("rules", help="List firewall rules")
    p.add_argument("interface", nargs="?", default="", help="Filter by interface")

    sub.add_parser("nat", help="List NAT rules")
    sub.add_parser("aliases", help="List aliases")

    p = sub.add_parser("alias", help="Show alias members")
    p.add_argument("name", help="Alias name")

    sub.add_parser("states", help="State table summary")

    p = sub.add_parser("states-top", help="Top connections by state count")
    p.add_argument("n", nargs="?", type=int, default=10)

    p = sub.add_parser("dhcp-leases", help="Show DHCP leases")
    p.add_argument("interface", nargs="?", default="", help="Filter by interface")

    sub.add_parser("arp", help="ARP table")
    sub.add_parser("routes", help="Routing table")
    sub.add_parser("services", help="List services")

    p = sub.add_parser("service", help="Control a service")
    p.add_argument("action", choices=["start", "stop", "restart"])
    p.add_argument("name", help="Service name")

    p = sub.add_parser("logs", help="Show firewall logs")
    p.add_argument("n", nargs="?", type=int, default=50)

    p = sub.add_parser("logs-filter", help="Search logs")
    p.add_argument("text", help="Text to search for")

    p = sub.add_parser("pfctl", help="Run pfctl command")
    p.add_argument("args", help="pfctl arguments")

    p = sub.add_parser("php", help="Run PHP code")
    p.add_argument("code", help="PHP code to execute")

    p = sub.add_parser("diag", help="Ping diagnostic")
    p.add_argument("host", help="Host to ping")

    sub.add_parser("backup", help="Download config backup (XML)")
    sub.add_parser("uptime", help="System uptime")
    sub.add_parser("cpu", help="CPU usage")
    sub.add_parser("memory", help="Memory usage")
    sub.add_parser("disk", help="Disk usage")
    sub.add_parser("temp", help="CPU temperature")
    sub.add_parser("pkg-list", help="List packages")

    p = sub.add_parser("dns-resolve", help="Resolve hostname")
    p.add_argument("host", help="Hostname to resolve")

    sub.add_parser("wireguard", help="WireGuard status")
    sub.add_parser("bgp", help="BGP summary")
    sub.add_parser("ospf", help="OSPF neighbors")
    sub.add_parser("tailscale", help="Tailscale status")
    sub.add_parser("snort", help="Snort status")

    p = sub.add_parser("raw", help="Run arbitrary command")
    p.add_argument("command", help="Command to run")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    cmd_map = {
        "status": cmd_status,
        "interfaces": cmd_interfaces,
        "gateways": cmd_gateways,
        "rules": cmd_rules,
        "nat": cmd_nat,
        "aliases": cmd_aliases,
        "alias": cmd_alias,
        "states": cmd_states,
        "states-top": cmd_states_top,
        "dhcp-leases": cmd_dhcp_leases,
        "arp": cmd_arp,
        "routes": cmd_routes,
        "services": cmd_services,
        "service": cmd_service,
        "logs": cmd_logs,
        "logs-filter": cmd_logs_filter,
        "pfctl": cmd_pfctl,
        "php": cmd_php,
        "diag": cmd_diag,
        "backup": cmd_backup,
        "uptime": cmd_uptime,
        "cpu": cmd_cpu,
        "memory": cmd_memory,
        "disk": cmd_disk,
        "temp": cmd_temp,
        "pkg-list": cmd_pkg_list,
        "dns-resolve": cmd_dns_resolve,
        "wireguard": cmd_wireguard,
        "bgp": cmd_bgp,
        "ospf": cmd_ospf,
        "tailscale": cmd_tailscale,
        "snort": cmd_snort,
        "raw": cmd_raw,
    }

    func = cmd_map.get(args.command)
    if func:
        func(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
