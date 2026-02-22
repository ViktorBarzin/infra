#!/usr/bin/env python3
"""Generate Terragrunt service stack files for all app-level services."""
import os
import textwrap

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Each service: (module_name, source_dir, [(arg_name, var_expr), ...], tier)
# var_expr is what goes on the right side of = in the module call.
# If var_expr starts with "var.", it's a variable passthrough and we declare the variable.
# If it's a literal string, we inline it.
# Special: "LOCAL_TIER" means we use local.tiers.<tier>
SERVICES = [
    ("blog", "blog", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("descheduler", "descheduler", []),
    ("drone", "drone", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("github_client_id", "var.drone_github_client_id"),
        ("github_client_secret", "var.drone_github_client_secret"),
        ("rpc_secret", "var.drone_rpc_secret"),
        ("webhook_secret", "var.drone_webhook_secret"),
        ("server_host", '"drone.viktorbarzin.me"'),
        ("server_proto", '"https"'),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("f1-stream", "f1-stream", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
        ("turn_secret", "var.coturn_turn_secret"),
        ("public_ip", "var.public_ip"),
    ]),
    ("coturn", "coturn", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:edge"),
        ("turn_secret", "var.coturn_turn_secret"),
        ("public_ip", "var.public_ip"),
    ]),
    ("hackmd", "hackmd", [
        ("hackmd_db_password", "var.hackmd_db_password"),
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("kms", "kms", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("k8s-dashboard", "k8s-dashboard", [
        ("tier", "LOCAL_TIER:cluster"),
        ("tls_secret_name", "var.tls_secret_name"),
        ("client_certificate_secret_name", "var.client_certificate_secret_name"),
    ]),
    ("privatebin", "privatebin", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("reloader", "reloader", [
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("shadowsocks", "shadowsocks", [
        ("password", "var.shadowsocks_password"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("city-guesser", "city-guesser", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("echo", "echo", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("url", "url-shortener", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("geolite_license_key", "var.url_shortener_geolite_license_key"),
        ("api_key", "var.url_shortener_api_key"),
        ("mysql_password", "var.url_shortener_mysql_password"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("webhook_handler", "webhook_handler", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("webhook_secret", "var.webhook_handler_secret"),
        ("fb_verify_token", "var.webhook_handler_fb_verify_token"),
        ("fb_page_token", "var.webhook_handler_fb_page_token"),
        ("fb_app_secret", "var.webhook_handler_fb_app_secret"),
        ("git_user", "var.webhook_handler_git_user"),
        ("git_token", "var.webhook_handler_git_token"),
        ("ssh_key", "var.webhook_handler_ssh_key"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("excalidraw", "excalidraw", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("travel_blog", "travel_blog", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("dashy", "dashy", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("send", "send", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("ytdlp", "youtube_dl", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
        ("openrouter_api_key", "var.openrouter_api_key"),
        ("slack_bot_token", "var.slack_bot_token"),
        ("slack_channel", "var.slack_channel"),
    ]),
    ("immich", "immich", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("postgresql_password", "var.immich_postgresql_password"),
        ("frame_api_key", "var.immich_frame_api_key"),
        ("homepage_token", 'var.homepage_credentials["immich"]["token"]'),
        ("tier", "LOCAL_TIER:gpu"),
    ]),
    ("resume", "resume", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
        ("database_url", "var.resume_database_url"),
        ("auth_secret", "var.resume_auth_secret"),
        ("smtp_password", 'var.mailserver_accounts["info@viktorbarzin.me"]'),
    ]),
    ("calibre", "calibre", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("homepage_username", 'var.homepage_credentials["calibre-web"]["username"]'),
        ("homepage_password", 'var.homepage_credentials["calibre-web"]["password"]'),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("audiobookshelf", "audiobookshelf", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("frigate", "frigate", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:gpu"),
    ]),
    ("paperless-ngx", "paperless-ngx", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("db_password", "var.paperless_db_password"),
        ("homepage_username", 'var.homepage_credentials["paperless-ngx"]["username"]'),
        ("homepage_password", 'var.homepage_credentials["paperless-ngx"]["password"]'),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("jsoncrack", "jsoncrack", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("servarr", "servarr", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
        ("aiostreams_database_connection_string", "var.aiostreams_database_connection_string"),
    ]),
    ("ollama", "ollama", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:gpu"),
        ("ollama_api_credentials", "var.ollama_api_credentials"),
    ]),
    ("ntfy", "ntfy", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("cyberchef", "cyberchef", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("diun", "diun", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("diun_nfty_token", "var.diun_nfty_token"),
        ("diun_slack_url", "var.diun_slack_url"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("meshcentral", "meshcentral", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("netbox", "netbox", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("nextcloud", "nextcloud", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("db_password", "var.nextcloud_db_password"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("homepage", "homepage", [
        ("tier", "LOCAL_TIER:aux"),
        ("tls_secret_name", "var.tls_secret_name"),
    ]),
    ("matrix", "matrix", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("linkwarden", "linkwarden", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("postgresql_password", "var.linkwarden_postgresql_password"),
        ("authentik_client_id", "var.linkwarden_authentik_client_id"),
        ("authentik_client_secret", "var.linkwarden_authentik_client_secret"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("actualbudget", "actualbudget", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:edge"),
        ("credentials", "var.actualbudget_credentials"),
    ]),
    ("owntracks", "owntracks", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("owntracks_credentials", "var.owntracks_credentials"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("dawarich", "dawarich", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("database_password", "var.dawarich_database_password"),
        ("geoapify_api_key", "var.geoapify_api_key"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("changedetection", "changedetection", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("tandoor", "tandoor", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tandoor_database_password", "var.tandoor_database_password"),
        ("tandoor_email_password", "var.tandoor_email_password"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("n8n", "n8n", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("postgresql_password", "var.n8n_postgresql_password"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("real-estate-crawler", "real-estate-crawler", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("db_password", "var.realestate_crawler_db_password"),
        ("notification_settings", "var.realestate_crawler_notification_settings"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("osm_routing", "osm-routing", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("tor-proxy", "tor-proxy", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("onlyoffice", "onlyoffice", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("db_password", "var.onlyoffice_db_password"),
        ("jwt_token", "var.onlyoffice_jwt_token"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("forgejo", "forgejo", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("freshrss", "freshrss", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("navidrome", "navidrome", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("networking-toolbox", "networking-toolbox", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("tuya-bridge", "tuya-bridge", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:cluster"),
        ("tiny_tuya_api_key", "var.tiny_tuya_api_key"),
        ("tiny_tuya_api_secret", "var.tiny_tuya_api_secret"),
        ("tiny_tuya_service_secret", "var.tiny_tuya_service_secret"),
        ("slack_url", "var.tiny_tuya_slack_url"),
    ]),
    ("stirling-pdf", "stirling-pdf", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("isponsorblocktv", "isponsorblocktv", [
        ("tier", "LOCAL_TIER:edge"),
    ]),
    ("ebook2audiobook", "ebook2audiobook", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:gpu"),
    ]),
    ("rybbit", "rybbit", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("clickhouse_password", "var.clickhouse_password"),
        ("postgres_password", "var.clickhouse_postgres_password"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("wealthfolio", "wealthfolio", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("wealthfolio_password_hash", "var.wealthfolio_password_hash"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("speedtest", "speedtest", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
        ("db_password", "var.speedtest_db_password"),
    ]),
    ("freedify", "freedify", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
        ("additional_credentials", "var.freedify_credentials"),
    ]),
    ("affine", "affine", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("postgresql_password", "var.affine_postgresql_password"),
        ("smtp_password", 'var.mailserver_accounts["info@viktorbarzin.me"]'),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("plotting-book", "plotting-book", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("health", "health", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("postgresql_password", "var.health_postgresql_password"),
        ("secret_key", "var.health_secret_key"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("whisper", "whisper", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("tier", "LOCAL_TIER:gpu"),
    ]),
    ("grampsweb", "grampsweb", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("smtp_password", 'var.mailserver_accounts["info@viktorbarzin.me"]'),
        ("tier", "LOCAL_TIER:aux"),
    ]),
    ("openclaw", "openclaw", [
        ("tls_secret_name", "var.tls_secret_name"),
        ("ssh_key", "var.openclaw_ssh_key"),
        ("skill_secrets", "var.openclaw_skill_secrets"),
        ("gemini_api_key", "var.gemini_api_key"),
        ("llama_api_key", "var.llama_api_key"),
        ("brave_api_key", "var.brave_api_key"),
        ("modal_api_key", "var.modal_api_key"),
        ("tier", "LOCAL_TIER:aux"),
    ]),
]

# Variable type overrides (var_name -> type declaration)
VAR_TYPES = {
    "tls_secret_name": "string",
    "client_certificate_secret_name": "string",
    "public_ip": "string",
    "hackmd_db_password": "string",
    "shadowsocks_password": "string",
    "openrouter_api_key": "string",
    "slack_bot_token": "string",
    "slack_channel": "string",
    "ollama_api_credentials": "string",
    "clickhouse_password": "string",
    "clickhouse_postgres_password": "string",
    "wealthfolio_password_hash": "string",
    "speedtest_db_password": "string",
    "affine_postgresql_password": "string",
    "health_postgresql_password": "string",
    "health_secret_key": "string",
    "gemini_api_key": "string",
    "llama_api_key": "string",
    "brave_api_key": "string",
    "modal_api_key": "string",
    "coturn_turn_secret": "string",
    "onlyoffice_db_password": "string",
    "onlyoffice_jwt_token": "string",
    "resume_database_url": "string",
    "resume_auth_secret": "string",
    "nextcloud_db_password": "string",
    "paperless_db_password": "string",
    "diun_nfty_token": "string",
    "diun_slack_url": "string",
    "dawarich_database_password": "string",
    "geoapify_api_key": "string",
    "tandoor_database_password": "string",
    "tandoor_email_password": "string",
    "n8n_postgresql_password": "string",
    "realestate_crawler_db_password": "string",
    "immich_postgresql_password": "string",
    "immich_frame_api_key": "string",
    "linkwarden_postgresql_password": "string",
    "linkwarden_authentik_client_id": "string",
    "linkwarden_authentik_client_secret": "string",
    "aiostreams_database_connection_string": "string",
    "tiny_tuya_api_key": "string",
    "tiny_tuya_api_secret": "string",
    "tiny_tuya_service_secret": "string",
    "tiny_tuya_slack_url": "string",
    "drone_github_client_id": "string",
    "drone_github_client_secret": "string",
    "drone_rpc_secret": "string",
    "drone_webhook_secret": "string",
    "url_shortener_geolite_license_key": "string",
    "url_shortener_api_key": "string",
    "url_shortener_mysql_password": "string",
    "webhook_handler_secret": "string",
    "webhook_handler_fb_verify_token": "string",
    "webhook_handler_fb_page_token": "string",
    "webhook_handler_fb_app_secret": "string",
    "webhook_handler_git_user": "string",
    "webhook_handler_git_token": "string",
    "webhook_handler_ssh_key": "string",
    "openclaw_ssh_key": "string",
    "openclaw_skill_secrets": "map(string)",
    "actualbudget_credentials": "map(any)",
    "freedify_credentials": "map(any)",
    "realestate_crawler_notification_settings": "map(string)",
    "homepage_credentials": "map(any)",
    "mailserver_accounts": "map(any)",
    "owntracks_credentials": "string",
}

TERRAGRUNT_HCL = """\
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}
"""

TIERS_BLOCK = """\
locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}
"""


def extract_var_name(expr):
    """Extract variable name from var.xxx or var.xxx["yyy"]["zzz"]."""
    if not expr.startswith("var."):
        return None
    # Get the base variable name (before any indexing)
    name = expr[4:]
    bracket = name.find("[")
    if bracket != -1:
        name = name[:bracket]
    return name


def gen_main_tf(mod_name, source_dir, args):
    """Generate main.tf content for a service stack."""
    lines = []

    # Collect variables needed
    vars_needed = {}
    needs_tiers = False
    for arg_name, var_expr in args:
        if var_expr.startswith("LOCAL_TIER:"):
            needs_tiers = True
            continue
        vname = extract_var_name(var_expr)
        if vname and vname not in vars_needed:
            vtype = VAR_TYPES.get(vname, None)
            vars_needed[vname] = vtype

    # Variable declarations
    for vname, vtype in vars_needed.items():
        if vtype:
            lines.append(f'variable "{vname}" {{ type = {vtype} }}')
        else:
            lines.append(f'variable "{vname}" {{}}')

    if vars_needed:
        lines.append("")

    # Tiers block if needed
    if needs_tiers:
        lines.append(TIERS_BLOCK)

    # Module call
    lines.append(f'module "{mod_name}" {{')
    lines.append(f'  source = "../../modules/kubernetes/{source_dir}"')
    for arg_name, var_expr in args:
        if var_expr.startswith("LOCAL_TIER:"):
            tier = var_expr.split(":")[1]
            val = f"local.tiers.{tier}"
        else:
            val = var_expr
        # Pad for alignment
        lines.append(f"  {arg_name:30s} = {val}")
    lines.append("}")
    lines.append("")

    return "\n".join(lines)


def main():
    stacks_dir = os.path.join(REPO_ROOT, "stacks")

    for mod_name, source_dir, args in SERVICES:
        # Use source_dir as the stack directory name for consistency
        # But some modules have different names than source dirs
        # Use the module name for the stack dir
        stack_dir = os.path.join(stacks_dir, mod_name)
        os.makedirs(stack_dir, exist_ok=True)

        # terragrunt.hcl
        tg_path = os.path.join(stack_dir, "terragrunt.hcl")
        with open(tg_path, "w") as f:
            f.write(TERRAGRUNT_HCL)

        # main.tf
        main_path = os.path.join(stack_dir, "main.tf")
        with open(main_path, "w") as f:
            f.write(gen_main_tf(mod_name, source_dir, args))

        # secrets symlink
        secrets_link = os.path.join(stack_dir, "secrets")
        if not os.path.exists(secrets_link):
            os.symlink("../../secrets", secrets_link)

        print(f"  Created stacks/{mod_name}/")

    print(f"\nGenerated {len(SERVICES)} service stacks")


if __name__ == "__main__":
    main()
