#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-ai.hnkt.vn}"
AICOWORKER_HEALTH_TIMEOUT_SECONDS="${AICOWORKER_HEALTH_TIMEOUT_SECONDS:-240}"
CADDY_CONTAINER="${CADDY_CONTAINER:-caddy}"
CADDYFILE="${CADDYFILE:-/root/.caddy/Caddyfile}"
AICOWORKER_PORT="${AICOWORKER_PORT:-23333}"
INSTALLER_URL="${INSTALLER_URL:-https://aicoworker.net/install-headless.sh}"
BRANDING_OVERLAY_DIR="${BRANDING_OVERLAY_DIR:-/var/www/hnkt/ai-hnkt-branded}"
BRANDING_CACHE_BUSTER="${BRANDING_CACHE_BUSTER:-hnkt-ai-branding-v4}"

log() {
  printf '[deploy-ai-hnkt] %s\n' "$*"
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

configure_branding_overlay() {
  log "Preparing HNKT AI frontend branding overlay"

  install -d -m 755 "${BRANDING_OVERLAY_DIR}" "${BRANDING_OVERLAY_DIR}/assets"

  BRANDING_OVERLAY_DIR="${BRANDING_OVERLAY_DIR}" AICOWORKER_PORT="${AICOWORKER_PORT}" BRANDING_CACHE_BUSTER="${BRANDING_CACHE_BUSTER}" python3 - <<'PY'
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.request import urlopen
import os
import re

root = Path(os.environ["BRANDING_OVERLAY_DIR"])
base = f"http://127.0.0.1:{os.environ['AICOWORKER_PORT']}/"
cache_buster = os.environ["BRANDING_CACHE_BUSTER"]

def fetch(path: str) -> bytes:
    with urlopen(urljoin(base, path), timeout=30) as response:
        return response.read()

html = fetch("/").decode("utf-8", "replace")
refs = set(re.findall(r'''(?:src|href)=["']([^"']+)["']''', html))
refs.add("./icon.svg")

for ref in sorted(refs):
    if ref.startswith(("data:", "http://", "https://", "#")):
        continue
    parsed = urlparse(urljoin(base, ref))
    rel = parsed.path.lstrip("/") or "index.html"
    dest = root / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        dest.write_bytes(fetch(parsed.path))
    except Exception as exc:
        print(f"[deploy-ai-hnkt] Skipping optional frontend asset {ref}: {exc}")

branding_script = r'''
    <script id="hnkt-ai-branding">
      (() => {
        const brand = "HNKT AI";
        const blockedCombined = ["Trang web GitHub", "Trang web và GitHub", "GitHub Website", "Website GitHub"];
        const blockedLinkLabels = new Set(["GitHub"]);
        const blockedPairedLabels = new Set(["Trang web", "Website", "ウェブサイト", "网站"]);
        const legacyName = "AI" + "Coworker";
        const legacySpacedName = "AI " + "Coworker";
        const legacyDomain = "aicoworker" + ".net";
        const blockedHrefParts = [legacyDomain, "github.com"];
        const skipTags = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEXTAREA", "INPUT"]);
        const replacements = [
          [legacyName, brand],
          [legacySpacedName, brand],
          ["agent." + legacyDomain, "HNKT AI relay"],
          [legacyDomain, brand]
        ];

        const replaceVisibleValue = (value) => {
          let next = value;
          for (const [from, to] of replacements) next = next.replaceAll(from, to);
          return next;
        };

        const replaceBrandText = (root) => {
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
              const parent = node.parentElement;
              if (!parent || skipTags.has(parent.tagName)) return NodeFilter.FILTER_REJECT;
              return replacements.some(([from]) => node.nodeValue.includes(from))
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT;
            }
          });
          const nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          for (const node of nodes) {
            node.nodeValue = replaceVisibleValue(node.nodeValue);
          }

          for (const element of document.querySelectorAll("[placeholder],[title],[aria-label]")) {
            for (const attr of ["placeholder", "title", "aria-label"]) {
              const value = element.getAttribute(attr);
              if (value && replacements.some(([from]) => value.includes(from))) {
                element.setAttribute(attr, replaceVisibleValue(value));
              }
            }
          }
        };

        const hideSettingLinks = () => {
          for (const element of document.querySelectorAll("a,button,[role='button'],[role='menuitem']")) {
            const text = (element.textContent || "").replace(/\s+/g, " ").trim();
            const href = [
              element.getAttribute("href"),
              element.getAttribute("data-href"),
              element.getAttribute("data-url")
            ].filter(Boolean).join(" ");
            const hasNearbyGitHub = (() => {
              let node = element.parentElement;
              for (let depth = 0; node && depth < 5; depth += 1, node = node.parentElement) {
                const nodeText = (node.textContent || "").replace(/\s+/g, " ").trim();
                const actionCount = node.querySelectorAll("a,button,[role='button'],[role='menuitem']").length;
                if (nodeText.includes("GitHub") && actionCount > 0 && actionCount <= 6) return true;
              }
              return false;
            })();
            if (
              blockedHrefParts.some((item) => href.includes(item)) ||
              blockedCombined.some((item) => text.includes(item)) ||
              blockedLinkLabels.has(text) ||
              (blockedPairedLabels.has(text) && hasNearbyGitHub)
            ) {
              element.style.setProperty("display", "none", "important");
            }
          }
        };

        let queued = false;
        const run = () => {
          if (queued) return;
          queued = true;
          requestAnimationFrame(() => {
            queued = false;
            document.title = brand;
            replaceBrandText(document.body || document.documentElement);
            hideSettingLinks();
          });
        };

        document.addEventListener("DOMContentLoaded", run);
        new MutationObserver(run).observe(document.documentElement, {
          childList: true,
          subtree: true,
          characterData: true
        });
        run();
      })();
    </script>
'''

def brand_text(value: str) -> str:
    value = value.replace("AICoworker", "HNKT AI")
    value = value.replace("AI Coworker", "HNKT AI")
    value = value.replace("https://aicoworker.net", "#")
    value = value.replace("http://aicoworker.net", "#")
    value = value.replace('docs:"Trang web",github:"GitHub"', 'docs:"",github:""')
    value = value.replace('docs:"Website",github:"GitHub"', 'docs:"",github:""')
    value = re.sub(r'docs:"(?:Trang web|Website|ウェブサイト|网站)"', 'docs:""', value)
    value = value.replace('github:"GitHub"', 'github:""')
    return value

index = root / "index.html"
html = brand_text(html)
html = re.sub(r"<title>.*?</title>", "<title>HNKT AI</title>", html, flags=re.I | re.S)
html = re.sub(
    r'''((?:src|href)=["'](?:\./)?(?:assets/[^"']+|__remote/shim\.js|icon\.svg))(?:\?[^"']*)?(["'])''',
    rf"\1?{cache_buster}\2",
    html,
)
if 'id="hnkt-ai-branding"' not in html:
    html = html.replace("</body>", branding_script + "\n  </body>")
index.write_text(html, encoding="utf-8")

for path in root.rglob("*"):
    if not path.is_file() or path.suffix.lower() not in {".html", ".js", ".css", ".svg", ".json", ".webmanifest"}:
        continue
    try:
        data = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    patched = brand_text(data)
    if patched != data:
        path.write_text(patched, encoding="utf-8")
PY

  chmod -R a+rX "${BRANDING_OVERLAY_DIR}"
  log "HNKT AI frontend overlay is ready at ${BRANDING_OVERLAY_DIR}"
}

detect_caddyfile() {
  local mounted_caddyfile=""

  mounted_caddyfile="$(
    docker inspect "${CADDY_CONTAINER}" \
      --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' \
      2>/dev/null || true
  )"

  if [[ -n "${mounted_caddyfile}" && -f "${mounted_caddyfile}" ]]; then
    CADDYFILE="${mounted_caddyfile}"
  fi
}

restore_caddyfile() {
  local backup="$1"

  cp -a "${backup}" "${CADDYFILE}"
  docker exec "${CADDY_CONTAINER}" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
}

configure_caddy() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required because this VPS serves sites through the Caddy container." >&2
    exit 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "${CADDY_CONTAINER}"; then
    echo "Expected a running Docker container named '${CADDY_CONTAINER}'; refusing to touch other web servers." >&2
    exit 1
  fi

  detect_caddyfile

  if [[ ! -f "${CADDYFILE}" ]]; then
    echo "Caddyfile not found at ${CADDYFILE}." >&2
    exit 1
  fi

  local backup="${CADDYFILE}.bak.aicoworker-${DOMAIN}.$(date +%Y%m%d%H%M%S)"
  cp -a "${CADDYFILE}" "${backup}"
  log "Backed up Caddyfile to ${backup}"

  DOMAIN="${DOMAIN}" AICOWORKER_PORT="${AICOWORKER_PORT}" CADDYFILE="${CADDYFILE}" BRANDING_OVERLAY_DIR="${BRANDING_OVERLAY_DIR}" python3 - <<'PY'
from pathlib import Path
import os
import re

domain = os.environ["DOMAIN"]
port = os.environ["AICOWORKER_PORT"]
overlay_dir = os.environ["BRANDING_OVERLAY_DIR"]
p = Path(os.environ["CADDYFILE"])
text = p.read_text()

start = f"# BEGIN AICoworker - {domain}"
end = f"# END AICoworker - {domain}"
block = f"""# BEGIN AICoworker - {domain}
{domain} {{
    encode zstd gzip
    root * {overlay_dir}

    @hnktFrontend {{
        path / /index.html /assets/* /__remote/shim.js /icon.svg /favicon* /manifest* /robots.txt
    }}
    handle @hnktFrontend {{
        try_files {{path}} /index.html
        file_server
    }}

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

  if ! docker exec "${CADDY_CONTAINER}" caddy validate --config /etc/caddy/Caddyfile; then
    restore_caddyfile "${backup}"
    echo "Caddy validation failed. Restored ${CADDYFILE} from ${backup}." >&2
    exit 1
  fi

  if ! docker exec "${CADDY_CONTAINER}" caddy reload --config /etc/caddy/Caddyfile; then
    restore_caddyfile "${backup}"
    echo "Caddy reload failed. Restored ${CADDYFILE} from ${backup}." >&2
    exit 1
  fi

  log "Caddy reloaded for ${DOMAIN}"
}

verify_domain() {
  log "Verifying AICoworker directly"
  curl -fsS "http://127.0.0.1:${AICOWORKER_PORT}/healthz"
  printf '\n'

  log "Verifying public HTTPS endpoint"
  curl -fsS --retry 18 --retry-all-errors --retry-delay 5 "https://${DOMAIN}/healthz"
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
  wait_for_local_health
  configure_branding_overlay
  configure_caddy
  verify_domain

  log "Provision details remain on the VPS journal/state files and are not printed in CI logs."
}

main "$@"
