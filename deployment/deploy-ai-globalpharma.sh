#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-ai.globalpharma.vn}"
AICOWORKER_HEALTH_TIMEOUT_SECONDS="${AICOWORKER_HEALTH_TIMEOUT_SECONDS:-240}"
CADDYFILE="${CADDYFILE:-/root/.caddy/Caddyfile}"
AICOWORKER_PORT="${AICOWORKER_PORT:-23333}"
INSTALLER_URL="${INSTALLER_URL:-https://aicoworker.net/install-headless.sh}"

log() {
  printf '[deploy-ai-globalpharma] %s\n' "$*"
}

sanitize_provision_output() {
  sed -u -E \
    -e 's#(AICW-PROVISION: SHARE_URL=).*#\1[masked]#' \
    -e 's#(AICW-PROVISION: PASSWORD=).*#\1[masked]#'
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This deploy script must run as root on the VPS." >&2
    exit 1
  fi
}

install_aicoworker() {
  log "Installing/upgrading AICoworker from ${INSTALLER_URL}"
  export AICOWORKER_HEALTH_TIMEOUT_SECONDS
  curl -fsSL "${INSTALLER_URL}" | bash 2>&1 | sanitize_provision_output
}

fix_cli_request_dir() {
  local cli="/usr/local/bin/aicoworker"
  local old='data_dir="/var/lib/aicoworker/AICoworker"'
  local new='data_dir="/var/lib/aicoworker/aicoworker/app"'

  if [[ ! -f "${cli}" ]] || ! grep -Fqx "${old}" "${cli}"; then
    return 0
  fi

  if [[ ! -d /var/lib/aicoworker/aicoworker/app ]]; then
    log "AICoworker app state directory is not present yet; leaving CLI request path unchanged"
    return 0
  fi

  cp -a "${cli}" "${cli}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i "s#^${old}#${new}#" "${cli}"
  chmod 755 "${cli}"
  log "Updated CLI remote request path to the active AICoworker state directory"
}

fix_state_ownership() {
  if ! id aicoworker >/dev/null 2>&1 || [[ ! -d /var/lib/aicoworker ]]; then
    return 0
  fi

  local changed=0
  local path owner_group

  for path in \
    /var/lib/aicoworker \
    /var/lib/aicoworker/AICoworker \
    /var/lib/aicoworker/aicoworker; do
    if [[ ! -e "${path}" ]]; then
      continue
    fi

    owner_group="$(stat -c '%U:%G' "${path}")"
    if [[ "${owner_group}" != "aicoworker:aicoworker" ]]; then
      chown -R aicoworker:aicoworker "${path}"
      changed=1
      log "Corrected ownership for ${path}"
    fi
  done

  if [[ "${changed}" == "1" ]] && systemctl list-unit-files aicoworker.service >/dev/null 2>&1; then
    systemctl restart aicoworker || true
    log "Restarted AICoworker after correcting state ownership"
  fi
}

wait_for_local_health() {
  log "Waiting for AICoworker local health on 127.0.0.1:${AICOWORKER_PORT}"
  for _ in $(seq 1 "${AICOWORKER_HEALTH_TIMEOUT_SECONDS}"); do
    if curl -fsS "http://127.0.0.1:${AICOWORKER_PORT}/healthz" >/dev/null 2>&1; then
      log "AICoworker local health is OK"
      return 0
    fi
    sleep 1
  done

  systemctl --no-pager --full status aicoworker || true
  journalctl -u aicoworker --no-pager -n 120 || true
  echo "AICoworker did not become healthy on 127.0.0.1:${AICOWORKER_PORT}." >&2
  exit 1
}

configure_caddy() {
  if ! docker ps --format '{{.Names}}' | grep -qx 'caddy'; then
    echo "Expected a running Docker container named 'caddy'; refusing to touch other web servers." >&2
    exit 1
  fi

  if [[ ! -f "${CADDYFILE}" ]]; then
    echo "Caddyfile not found at ${CADDYFILE}." >&2
    exit 1
  fi

  local backup="${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "${CADDYFILE}" "${backup}"
  log "Backed up Caddyfile to ${backup}"

  DOMAIN="${DOMAIN}" AICOWORKER_PORT="${AICOWORKER_PORT}" CADDYFILE="${CADDYFILE}" python3 - <<'PY'
from pathlib import Path
import os
import re

domain = os.environ["DOMAIN"]
port = os.environ["AICOWORKER_PORT"]
p = Path(os.environ["CADDYFILE"])
text = p.read_text()

start = f"# BEGIN AICoworker - {domain}"
end = f"# END AICoworker - {domain}"
block = f"""# BEGIN AICoworker - {domain}
{domain} {{
    encode zstd gzip

    reverse_proxy 127.0.0.1:{port} {{
        header_up Host {{host}}
        header_up X-Real-IP {{remote_host}}
        header_up X-Forwarded-Proto https
    }}
}}
# END AICoworker - {domain}
"""

if start in text and end in text:
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end) + r"\n?", re.S)
    new_text = pattern.sub(block, text)
elif re.search(rf"(?m)^\s*{re.escape(domain)}\s*\{{", text):
    raise SystemExit(f"Found an existing unmarked {domain} block; refusing to edit automatically.")
else:
    new_text = text + ("" if text.endswith("\n") else "\n") + "\n" + block

p.write_text(new_text)
PY

  docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null
  docker exec caddy caddy validate --config /etc/caddy/Caddyfile
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile
  log "Caddy reloaded for ${DOMAIN}"
}

verify_domain() {
  log "Verifying local Caddy proxy"
  curl -fsS -H "Host: ${DOMAIN}" "http://127.0.0.1/healthz"
  printf '\n'

  log "Verifying public HTTPS endpoint"
  curl -fsS --retry 12 --retry-all-errors --retry-delay 5 "https://${DOMAIN}/healthz"
  printf '\n'

  log "HTTP headers from https://${DOMAIN}/"
  curl -fsS --retry 6 --retry-all-errors --retry-delay 5 -D - -o /dev/null "https://${DOMAIN}/" | sed -n '1,30p'
}

main() {
  require_root
  if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
    log "Skipping installer because SKIP_INSTALL=1"
  else
    install_aicoworker
  fi
  fix_cli_request_dir
  fix_state_ownership
  wait_for_local_health
  configure_caddy
  verify_domain

  log "Provision details remain on the VPS journal and are not printed in CI logs."
}

main "$@"
