#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-hq.striver.ai.vn}"
AICOWORKER_PORT="${AICOWORKER_PORT:-23333}"
AICOWORKER_HEALTH_TIMEOUT_SECONDS="${AICOWORKER_HEALTH_TIMEOUT_SECONDS:-300}"
NGINX_CONTAINER="${NGINX_CONTAINER:-nginx-proxy}"
NGINX_CONF="${NGINX_CONF:-/opt/npm/nginx.conf}"
ACME_WEBROOT="${ACME_WEBROOT:-/opt/npm/ssl/acme}"
CERTBOT_CERT_NAME="${CERTBOT_CERT_NAME:-${DOMAIN}}"
NGINX_SSL_NAME="${NGINX_SSL_NAME:-hq-aicoworker}"
INSTALL_DIR="${INSTALL_DIR:-/opt/aicoworker}"
STATE_HOME="${STATE_HOME:-/var/lib/aicoworker}"
RELEASE_API_URL="${RELEASE_API_URL:-https://api.github.com/repos/Neurons-ai/AICoworker/releases/latest}"
CLI_DOWNLOAD_URL="${CLI_DOWNLOAD_URL:-https://aicoworker.net/aicoworker-cli.sh}"

log() {
  printf '[deploy-hq-striver] %s\n' "$*"
}

sanitize_provision_output() {
  sed -u -E \
    -e 's#(AICW-PROVISION: SHARE_URL=).*#\1[masked]#' \
    -e 's#(AICW-PROVISION: PASSWORD=).*#\1[masked]#' \
    -e 's#(One-time password: ).*#\1[masked]#'
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This deploy script must run as root on the VPS." >&2
    exit 1
  fi
}

install_dependencies() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This deploy script currently supports the Ubuntu/Debian VPS used for ${DOMAIN}." >&2
    exit 1
  fi

  local fuse_lib="libfuse2"
  local gtk_pkg="libgtk-3-0"
  local asound_pkg="libasound2"
  if apt-cache show libfuse2t64 >/dev/null 2>&1; then fuse_lib="libfuse2t64"; fi
  if apt-cache show libgtk-3-0t64 >/dev/null 2>&1; then gtk_pkg="libgtk-3-0t64"; fi
  if apt-cache show libasound2t64 >/dev/null 2>&1; then asound_pkg="libasound2t64"; fi

  export DEBIAN_FRONTEND=noninteractive
  log "Installing required runtime packages without replacing fuse3"
  apt-get update
  apt-get install -y --no-install-recommends \
    curl ca-certificates openssl python3 xvfb "${fuse_lib}" "${gtk_pkg}" libnss3 \
    "${asound_pkg}" libxss1 libxtst6 libgbm1 libdrm2 libx11-xcb1 bubblewrap \
    socat ripgrep certbot
}

ensure_user_and_dirs() {
  local service_user="aicoworker"

  if ! id "${service_user}" >/dev/null 2>&1; then
    log "Creating service user ${service_user}"
    useradd --system --create-home --home-dir "${STATE_HOME}" --shell /usr/sbin/nologin "${service_user}"
  fi

  install -d -m 755 -o "${service_user}" -g "${service_user}" "${INSTALL_DIR}"
  install -d -m 700 -o "${service_user}" -g "${service_user}" "${STATE_HOME}" "${STATE_HOME}/tmp"
  rm -f "${INSTALL_DIR}/owner-credentials.txt" 2>/dev/null || true

  if [[ ! -e "${STATE_HOME}/owner-credentials.txt" ]]; then
    install -m 600 -o "${service_user}" -g "${service_user}" /dev/null "${STATE_HOME}/owner-credentials.txt"
  fi
}

download_appimage() {
  local app_image="${INSTALL_DIR}/AICoworker.AppImage"
  local arch release_arch asset_arch release_json download_url update_yml_url asset_name
  local expected_sha512 actual_sha512 current_url temp

  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) release_arch="x64"; asset_arch="x86_64" ;;
    aarch64|arm64) release_arch="arm64"; asset_arch="arm64" ;;
    *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
  esac

  release_json="$(mktemp)"
  temp=""
  curl -fsSL "${RELEASE_API_URL}" -o "${release_json}"

  download_url="$(
    python3 - "${release_json}" "${asset_arch}" "${release_arch}" <<'PY'
import json
import sys

path, asset_arch, release_arch = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
for suffix in (f"linux-{asset_arch}.AppImage", f"linux-{release_arch}.AppImage"):
    for asset in data.get("assets", []):
        url = asset.get("browser_download_url") or ""
        if url.endswith(suffix):
            print(url)
            raise SystemExit
PY
  )"
  [[ -n "${download_url}" ]] || { echo "No Linux ${release_arch} AppImage found." >&2; exit 1; }

  update_yml_url="$(
    python3 - "${release_json}" "${release_arch}" <<'PY'
import json
import sys

path, release_arch = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
preferred = ["latest-linux-arm64.yml"] if release_arch == "arm64" else []
preferred.append("latest-linux.yml")
for name in preferred:
    for asset in data.get("assets", []):
        if asset.get("name") == name:
            print(asset.get("browser_download_url"))
            raise SystemExit
PY
  )"
  [[ -n "${update_yml_url}" ]] || { echo "Release has no Linux checksum manifest." >&2; exit 1; }

  asset_name="${download_url##*/}"
  expected_sha512="$(
    curl -fsSL "${update_yml_url}" |
      awk -v target="${asset_name}" '
        $1 == "-" && $2 == "url:" { current = $3; next }
        $1 == "sha512:" && current == target { print $2; exit }
      '
  )"
  [[ -n "${expected_sha512}" ]] || { echo "Checksum manifest has no sha512 for ${asset_name}." >&2; exit 1; }

  current_url=""
  [[ -f "${INSTALL_DIR}/release-url" ]] && current_url="$(cat "${INSTALL_DIR}/release-url")"
  if [[ -x "${app_image}" && "${current_url}" == "${download_url}" ]]; then
    log "Latest AppImage is already installed"
    rm -f "${release_json}"
    APPIMAGE_CHANGED=0
    return 0
  fi

  log "Downloading ${asset_name}"
  temp="$(mktemp "${INSTALL_DIR}/AICoworker.AppImage.XXXXXX")"
  curl -fL --retry 3 -o "${temp}" "${download_url}"
  actual_sha512="$(openssl dgst -sha512 -binary "${temp}" | openssl base64 -A)"
  [[ "${actual_sha512}" == "${expected_sha512}" ]] || { echo "AppImage SHA-512 checksum mismatch." >&2; exit 1; }

  chmod 755 "${temp}"
  chown aicoworker:aicoworker "${temp}"
  mv -f "${temp}" "${app_image}"
  printf '%s\n' "${download_url}" > "${INSTALL_DIR}/release-url"
  chown aicoworker:aicoworker "${INSTALL_DIR}/release-url"
  rm -f "${release_json}"
  APPIMAGE_CHANGED=1
}

write_systemd_service() {
  local unit_path="/etc/systemd/system/aicoworker.service"
  local temp_unit unit_changed

  temp_unit="$(mktemp)"
  cat > "${temp_unit}" <<UNIT
[Unit]
Description=AICoworker headless service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=aicoworker
Group=aicoworker
Environment=HOME=${STATE_HOME}
Environment=XDG_CONFIG_HOME=${STATE_HOME}
Environment=AICOWORKER_HEADLESS=1
Environment=AICOWORKER_OWNER_CREDENTIALS_PATH=${STATE_HOME}/owner-credentials.txt
Environment=APPIMAGE_EXTRACT_AND_RUN=1
Environment=TMPDIR=${STATE_HOME}/tmp
LimitCORE=0
ExecStart=/usr/bin/xvfb-run -a ${INSTALL_DIR}/AICoworker.AppImage --headless --provision-remote --no-sandbox
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  unit_changed=0
  if [[ ! -f "${unit_path}" ]] || ! cmp -s "${temp_unit}" "${unit_path}"; then
    [[ -f "${unit_path}" ]] && cp -a "${unit_path}" "${unit_path}.bak.$(date +%Y%m%d%H%M%S)"
    install -m 0644 "${temp_unit}" "${unit_path}"
    unit_changed=1
  fi
  rm -f "${temp_unit}"

  systemctl daemon-reload
  systemctl enable aicoworker >/dev/null

  if ! systemctl is-active --quiet aicoworker; then
    log "Starting AICoworker"
    systemctl start aicoworker
  elif [[ "${APPIMAGE_CHANGED:-0}" == "1" || "${unit_changed}" == "1" ]]; then
    log "Restarting AICoworker because the binary or unit changed"
    systemctl restart aicoworker
  else
    log "AICoworker service is already running with the current unit"
  fi
}

install_and_patch_cli() {
  local cli="/usr/local/bin/aicoworker"

  curl -fsSL "${CLI_DOWNLOAD_URL}" -o "${cli}"
  chmod 755 "${cli}"

  python3 - <<'PY'
from pathlib import Path

p = Path("/usr/local/bin/aicoworker")
text = p.read_text()
text = text.replace(
    'data_dir="/var/lib/aicoworker/AICoworker"',
    'data_dir="/var/lib/aicoworker/aicoworker/app"',
)
lines = text.splitlines(keepends=True)
out = []
i = 0
while i < len(lines):
    if (
        i + 4 < len(lines)
        and lines[i].strip() == 'install -d -m 700 -o aicoworker -g aicoworker "${request_dir}"'
        and lines[i + 1].strip() == 'rm -f "${response}"'
        and lines[i + 2].strip() == 'printf \'%s\\n\' "${body}" > "${request_dir}/${kind}.json"'
        and lines[i + 3].strip() == 'chown aicoworker:aicoworker "${request_dir}/${kind}.json"'
        and lines[i + 4].strip() == 'chmod 600 "${request_dir}/${kind}.json"'
    ):
        out.extend(
            [
                '  install -d -m 700 -o aicoworker -g aicoworker "${request_dir}"\n',
                '  rm -f "${response}"\n',
                '  local request_file="${request_dir}/${kind}.json"\n',
                '  local request_temp\n',
                '  request_temp="$(mktemp "${request_dir}/${kind}.json.XXXXXX")"\n',
                '  printf \'%s\\n\' "${body}" > "${request_temp}"\n',
                '  chown aicoworker:aicoworker "${request_temp}"\n',
                '  chmod 600 "${request_temp}"\n',
                '  mv -f "${request_temp}" "${request_file}"\n',
            ]
        )
        i += 5
        continue
    if 'request "status"' in lines[i] and "shareUrl" in lines[i] and "sed -n" in lines[i]:
        out.append('    request "status" \'{}\' | sed -n \'s/.*"shareUrl": *"\\([^"]*\\)".*/\\1/p\'\n')
        i += 1
        continue
    out.append(lines[i])
    i += 1
p.write_text("".join(out))
PY

  bash -n "${cli}"
  chmod 755 "${cli}"
  log "Installed AICoworker CLI with VPS-safe request handling"
}

wait_for_local_health() {
  log "Waiting for local health on 127.0.0.1:${AICOWORKER_PORT}"
  for _ in $(seq 1 "${AICOWORKER_HEALTH_TIMEOUT_SECONDS}"); do
    if curl -fsS "http://127.0.0.1:${AICOWORKER_PORT}/healthz" >/dev/null 2>&1; then
      log "AICoworker local health is OK"
      return 0
    fi
    sleep 1
  done

  systemctl --no-pager --full status aicoworker || true
  journalctl -u aicoworker --no-pager -n 160 | sanitize_provision_output || true
  echo "AICoworker did not become healthy on 127.0.0.1:${AICOWORKER_PORT}." >&2
  exit 1
}

backup_nginx_conf() {
  local backup_dir="/opt/deploy-backups/aicoworker-${DOMAIN}-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${backup_dir}"
  cp -a "${NGINX_CONF}" "${backup_dir}/nginx.conf"
  printf '%s\n' "${backup_dir}/nginx.conf"
}

restore_nginx_conf() {
  local backup="$1"
  cp -a "${backup}" "${NGINX_CONF}"
  docker exec "${NGINX_CONTAINER}" nginx -s reload >/dev/null 2>&1 || true
}

test_and_reload_nginx() {
  local backup="$1"

  if ! docker exec "${NGINX_CONTAINER}" nginx -t; then
    restore_nginx_conf "${backup}"
    echo "nginx validation failed. Restored ${NGINX_CONF} from ${backup}." >&2
    exit 1
  fi

  if ! docker exec "${NGINX_CONTAINER}" nginx -s reload; then
    restore_nginx_conf "${backup}"
    echo "nginx reload failed. Restored ${NGINX_CONF} from ${backup}." >&2
    exit 1
  fi
}

upsert_nginx_block() {
  local include_https="$1"

  DOMAIN="${DOMAIN}" \
  AICOWORKER_PORT="${AICOWORKER_PORT}" \
  NGINX_CONF="${NGINX_CONF}" \
  NGINX_SSL_NAME="${NGINX_SSL_NAME}" \
  INCLUDE_HTTPS="${include_https}" \
    python3 - <<'PY'
from pathlib import Path
import os
import re

domain = os.environ["DOMAIN"]
port = os.environ["AICOWORKER_PORT"]
nginx_conf = Path(os.environ["NGINX_CONF"])
ssl_name = os.environ["NGINX_SSL_NAME"]
include_https = os.environ["INCLUDE_HTTPS"] == "1"

text = nginx_conf.read_text(encoding="utf-8", errors="replace")
start_marker = f"    # BEGIN AICoworker {domain} managed by Codex"
end_marker = f"    # END AICoworker {domain} managed by Codex"

block = f'''    # BEGIN AICoworker {domain} managed by Codex
    server {{
        listen 80;
        server_name {domain};

        location ^~ /.well-known/acme-challenge/ {{
            root /etc/nginx/ssl/acme;
            try_files $uri =404;
        }}

        location / {{
            return 301 https://$host$request_uri;
        }}
    }}
'''

if include_https:
    block += f'''
    server {{
        listen 443 ssl;
        http2 on;
        server_name {domain};
        ssl_certificate     /etc/nginx/ssl/{ssl_name}/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/{ssl_name}/privkey.pem;
        client_max_body_size 128m;
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
        proxy_send_timeout 720s;
        add_header Strict-Transport-Security "max-age=31536000" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;

        location / {{
            proxy_pass http://127.0.0.1:{port};
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_cache off;
            proxy_redirect off;
        }}
    }}
'''

block += f"    # END AICoworker {domain} managed by Codex"

if start_marker in text and end_marker in text:
    pattern = re.compile(re.escape(start_marker) + r".*?" + re.escape(end_marker), re.S)
    text = pattern.sub(block, text)
elif re.search(rf"(?m)^\s*server_name\s+{re.escape(domain)}\s*;", text):
    raise SystemExit(f"Found an existing unmarked server_name for {domain}; refusing automatic edit.")
else:
    idx = text.rfind("\n}")
    if idx == -1:
        raise SystemExit("Could not find final nginx http closing brace.")
    text = text[:idx] + "\n\n" + block + text[idx:]

nginx_conf.write_text(text, encoding="utf-8")
PY
}

ensure_nginx_proxy() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required because this VPS serves public HTTP(S) through ${NGINX_CONTAINER}." >&2
    exit 1
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "${NGINX_CONTAINER}"; then
    echo "Expected a running Docker container named ${NGINX_CONTAINER}; refusing to touch another web server." >&2
    exit 1
  fi
  if [[ ! -f "${NGINX_CONF}" ]]; then
    echo "nginx config not found: ${NGINX_CONF}" >&2
    exit 1
  fi
}

ensure_http_acme_route() {
  local backup probe probe_path

  backup="$(backup_nginx_conf)"
  upsert_nginx_block 0
  test_and_reload_nginx "${backup}"

  install -d -m 0755 "${ACME_WEBROOT}/.well-known/acme-challenge"
  probe="aicoworker-probe-$(date -u +%Y%m%dT%H%M%SZ).txt"
  probe_path="${ACME_WEBROOT}/.well-known/acme-challenge/${probe}"
  printf 'ok\n' > "${probe_path}"
  curl -fsS "http://${DOMAIN}/.well-known/acme-challenge/${probe}" | grep -qx "ok"
  rm -f "${probe_path}"
  log "HTTP ACME route is reachable for ${DOMAIN}"
}

ensure_certificate() {
  local lineage="/etc/letsencrypt/live/${CERTBOT_CERT_NAME}"
  local target="/opt/npm/ssl/${NGINX_SSL_NAME}"

  if [[ -f "${lineage}/fullchain.pem" ]] &&
     openssl x509 -checkend 2592000 -noout -in "${lineage}/fullchain.pem" >/dev/null 2>&1; then
    log "Existing Let's Encrypt certificate is valid for at least 30 days"
  else
    log "Requesting Let's Encrypt certificate for ${DOMAIN}"
    certbot certonly --webroot -w "${ACME_WEBROOT}" -d "${DOMAIN}" \
      --cert-name "${CERTBOT_CERT_NAME}" --agree-tos \
      --register-unsafely-without-email --non-interactive
  fi

  install -d -m 0755 "${target}"
  install -m 0644 "${lineage}/fullchain.pem" "${target}/fullchain.pem"
  install -m 0600 "${lineage}/privkey.pem" "${target}/privkey.pem"

  cat > /etc/letsencrypt/renewal-hooks/deploy/hq-aicoworker-nginx-copy.sh <<HOOK
#!/bin/sh
set -eu
if [ "\${RENEWED_LINEAGE:-}" != "/etc/letsencrypt/live/${CERTBOT_CERT_NAME}" ]; then
  exit 0
fi
install -d -m 0755 /opt/npm/ssl/${NGINX_SSL_NAME}
install -m 0644 "\$RENEWED_LINEAGE/fullchain.pem" /opt/npm/ssl/${NGINX_SSL_NAME}/fullchain.pem
install -m 0600 "\$RENEWED_LINEAGE/privkey.pem" /opt/npm/ssl/${NGINX_SSL_NAME}/privkey.pem
docker exec ${NGINX_CONTAINER} nginx -t
docker exec ${NGINX_CONTAINER} nginx -s reload
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/hq-aicoworker-nginx-copy.sh
}

configure_https_proxy() {
  local backup

  backup="$(backup_nginx_conf)"
  upsert_nginx_block 1
  test_and_reload_nginx "${backup}"
  log "nginx-proxy routes ${DOMAIN} to 127.0.0.1:${AICOWORKER_PORT}"
}

configure_port_guard() {
  local unit="/etc/systemd/system/aicoworker-port-guard.service"

  cat > "${unit}" <<UNIT
[Unit]
Description=Restrict direct public access to AICoworker HTTP port
After=network-online.target
Before=aicoworker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/iptables -C INPUT -p tcp --dport ${AICOWORKER_PORT} ! -s 127.0.0.1 -j DROP 2>/dev/null || /usr/sbin/iptables -I INPUT -p tcp --dport ${AICOWORKER_PORT} ! -s 127.0.0.1 -j DROP'
ExecStart=/bin/sh -c 'command -v ip6tables >/dev/null 2>&1 && (/usr/sbin/ip6tables -C INPUT -p tcp --dport ${AICOWORKER_PORT} -j DROP 2>/dev/null || /usr/sbin/ip6tables -I INPUT -p tcp --dport ${AICOWORKER_PORT} -j DROP) || true'
ExecStop=/bin/sh -c '/usr/sbin/iptables -D INPUT -p tcp --dport ${AICOWORKER_PORT} ! -s 127.0.0.1 -j DROP 2>/dev/null || true'
ExecStop=/bin/sh -c 'command -v ip6tables >/dev/null 2>&1 && /usr/sbin/ip6tables -D INPUT -p tcp --dport ${AICOWORKER_PORT} -j DROP 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now aicoworker-port-guard >/dev/null
  log "Direct public access to port ${AICOWORKER_PORT} is blocked; localhost remains available"
}

verify_domain() {
  log "Verifying local app health"
  curl -fsS "http://127.0.0.1:${AICOWORKER_PORT}/healthz"
  printf '\n'

  log "Verifying public HTTPS app health"
  curl -fsS --retry 12 --retry-all-errors --retry-delay 5 "https://${DOMAIN}/healthz"
  printf '\n'

  log "HTTP headers from https://${DOMAIN}/"
  curl -fsS --retry 6 --retry-all-errors --retry-delay 5 -D - -o /dev/null "https://${DOMAIN}/" | sed -n '1,30p'
}

main() {
  require_root
  install_dependencies
  ensure_user_and_dirs
  download_appimage
  write_systemd_service
  install_and_patch_cli
  wait_for_local_health
  ensure_nginx_proxy
  ensure_http_acme_route
  ensure_certificate
  configure_https_proxy
  configure_port_guard
  verify_domain
  log "Deploy complete. Provision secrets remain on the VPS and are not printed in CI logs."
}

main "$@"
