#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${SCRIPT_DIR}/release"
TEMP_DIR="${SCRIPT_DIR}/temp"
RU_NON_RU_SOURCE="${SCRIPT_DIR}/ru-non-ru-domains.txt"

mkdir -p "${RELEASE_DIR}"
mkdir -p "${TEMP_DIR}"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

require_file() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "❌ File not found: ${file}" >&2
    exit 1
  fi
}

download() {
  local url="$1"
  local out="$2"
  local label="$3"

  echo "  ${label}..."
  curl -fsSL "${url}" -o "${out}"
}

clean_plain_file() {
  local input="$1"
  local output="$2"

  awk '
    {
      sub(/\r$/, "", $0)
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*#/) next
      print $0
    }
  ' "${input}" > "${output}"
}

echo "Подготовка..."
require_file "${RU_NON_RU_SOURCE}"

# URL списков
ANTIFILTER_DOMAINS_URL="https://community.antifilter.download/list/domains.lst"
ANTIFILTER_COMMUNITY_IP_URL="https://community.antifilter.download/list/community.lst"
ALLYOUNEED_IP_URL="https://antifilter.download/list/allyouneed.lst"
ADGUARD_REJECT_URL="https://raw.githubusercontent.com/Loyalsoldier/surge-rules/refs/heads/release/ruleset/reject.txt"
RU_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/ru.txt"
PRIVATE_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/private.txt"

echo "Загрузка списков..."

download "${ANTIFILTER_DOMAINS_URL}" "${TEMP_DIR}/domains.raw" "domains.lst (community.antifilter - домены)"
download "${ANTIFILTER_COMMUNITY_IP_URL}" "${TEMP_DIR}/community-ip.raw" "community.lst (community.antifilter - IP)"
download "${ALLYOUNEED_IP_URL}" "${TEMP_DIR}/allyouneed-ip.raw" "allyouneed.lst (antifilter - IP)"
download "${ADGUARD_REJECT_URL}" "${TEMP_DIR}/reject.raw" "reject.txt (Loyalsoldier - реклама)"
download "${RU_IP_URL}" "${TEMP_DIR}/ru.raw" "ru.txt (Loyalsoldier geoip - Россия)"
download "${PRIVATE_IP_URL}" "${TEMP_DIR}/private.raw" "private.txt (Loyalsoldier geoip - Private)"

echo "Нормализация..."

clean_plain_file "${TEMP_DIR}/domains.raw" "${TEMP_DIR}/domains.lst"
clean_plain_file "${TEMP_DIR}/community-ip.raw" "${TEMP_DIR}/community-ip.lst"
clean_plain_file "${TEMP_DIR}/allyouneed-ip.raw" "${TEMP_DIR}/allyouneed-ip.lst"
clean_plain_file "${TEMP_DIR}/reject.raw" "${TEMP_DIR}/reject.txt"
clean_plain_file "${TEMP_DIR}/ru.raw" "${TEMP_DIR}/ru.txt"
clean_plain_file "${TEMP_DIR}/private.raw" "${TEMP_DIR}/private.txt"

cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u > "${TEMP_DIR}/merged-antifilter-ip.lst"

echo "Проверка и подготовка ru-non-ru-domains.txt..."

python3 - "${RU_NON_RU_SOURCE}" "${TEMP_DIR}/ru-non-ru-domains.normalized.txt" "${TEMP_DIR}/ru-non-ru-domains.stats.json" << 'PY'
import json
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
normalized_out = pathlib.Path(sys.argv[2])
stats_out = pathlib.Path(sys.argv[3])

domain_re = re.compile(
    r"^(?=.{1,253}$)(?!-)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$"
)

normalized_lines = []
seen = set()
suffix_count = 0
full_count = 0

for lineno, raw_line in enumerate(src.read_text(encoding="utf-8").splitlines(), start=1):
    line = raw_line.strip()

    if not line or line.startswith("#"):
        continue

    kind = "suffix"
    if line.startswith("full:"):
        kind = "full"
        line = line[5:].strip()

    line = line.lower().rstrip(".")

    if not domain_re.match(line):
        raise SystemExit(f"Invalid domain in {src.name}:{lineno}: {raw_line}")

    key = f"{kind}:{line}"
    if key in seen:
        continue
    seen.add(key)

    normalized_lines.append(key)

    if kind == "full":
        full_count += 1
    else:
        suffix_count += 1

normalized_out.write_text(
    "\n".join(normalized_lines) + ("\n" if normalized_lines else ""),
    encoding="utf-8"
)

stats_out.write_text(
    json.dumps(
        {
            "total": len(normalized_lines),
            "suffix": suffix_count,
            "full": full_count,
        },
        indent=2,
        ensure_ascii=False,
    ) + "\n",
    encoding="utf-8",
)
PY

RU_NON_RU_NORMALIZED="${TEMP_DIR}/ru-non-ru-domains.normalized.txt"

echo "Конвертация..."

# ========================================
# MIHOMO/CLASH/SURGE (Surge формат без ACTION)
# ========================================
echo "  Mihomo/Clash/Surge..."

# Antifilter домены
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/mihomo-antifilter-domains.txt"

# Antifilter IP
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/merged-antifilter-ip.lst" > "${RELEASE_DIR}/mihomo-antifilter-ip.txt"

# AdGuard reject
cp "${TEMP_DIR}/reject.txt" "${RELEASE_DIR}/mihomo-adguard-domains.txt"

# Loyalsoldier GeoIP - Россия
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/ru.txt" > "${RELEASE_DIR}/mihomo-ru-ip.txt"

# Loyalsoldier GeoIP - Private
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/private.txt" > "${RELEASE_DIR}/mihomo-private-ip.txt"

# RU non-RU domains
awk '
  /^suffix:/ { sub(/^suffix:/, "", $0); print "DOMAIN-SUFFIX," $0; next }
  /^full:/   { sub(/^full:/,   "", $0); print "DOMAIN," $0; next }
' "${RU_NON_RU_NORMALIZED}" > "${RELEASE_DIR}/mihomo-ru-non-ru-domains.txt"

# ========================================
# SHADOWROCKET (Surge формат без ACTION)
# ========================================
echo "  Shadowrocket..."

# Antifilter домены
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/shadowrocket-antifilter-domains.txt"

# Antifilter IP
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/merged-antifilter-ip.lst" > "${RELEASE_DIR}/shadowrocket-antifilter-ip.txt"

# AdGuard reject
sed -e 's/^DOMAIN-SUFFIX,//' "${TEMP_DIR}/reject.txt" > "${RELEASE_DIR}/shadowrocket-adguard-domains.txt"

# Loyalsoldier GeoIP - Россия
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/ru.txt" > "${RELEASE_DIR}/shadowrocket-ru-ip.txt"

# Loyalsoldier GeoIP - Private
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/private.txt" > "${RELEASE_DIR}/shadowrocket-private-ip.txt"

# RU non-RU domains
awk '
  /^suffix:/ { sub(/^suffix:/, "", $0); print "DOMAIN-SUFFIX," $0; next }
  /^full:/   { sub(/^full:/,   "", $0); print "DOMAIN," $0; next }
' "${RU_NON_RU_NORMALIZED}" > "${RELEASE_DIR}/shadowrocket-ru-non-ru-domains.txt"

# ========================================
# SING-BOX (JSON через Python)
# ========================================
echo "  Sing-box (Python)..."

# Antifilter домены
python3 - "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/singbox-antifilter-domains.json" << 'PY'
import json
import pathlib
import sys

domains = [line.strip() for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
result = {
    "version": 1,
    "rules": [{"domain_suffix": d} for d in domains]
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

# Antifilter IP
python3 - "${TEMP_DIR}/merged-antifilter-ip.lst" > "${RELEASE_DIR}/singbox-antifilter-ip.json" << 'PY'
import json
import pathlib
import sys

ips = [line.strip() for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
result = {
    "version": 1,
    "rules": [{"ip_cidr": ip} for ip in ips]
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

# AdGuard reject
python3 - "${TEMP_DIR}/reject.txt" > "${RELEASE_DIR}/singbox-adguard-domains.json" << 'PY'
import json
import pathlib
import sys

rules = []
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    if line.startswith("DOMAIN-SUFFIX,"):
        rules.append({"domain_suffix": line.split(",", 1)[1]})
    elif line.startswith("DOMAIN,"):
        rules.append({"domain": line.split(",", 1)[1]})

result = {
    "version": 1,
    "rules": rules
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

# Loyalsoldier GeoIP - Россия
python3 - "${TEMP_DIR}/ru.txt" > "${RELEASE_DIR}/singbox-ru-ip.json" << 'PY'
import json
import pathlib
import sys

ips = [line.strip() for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
result = {
    "version": 1,
    "rules": [{"ip_cidr": ip} for ip in ips]
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

# Loyalsoldier GeoIP - Private
python3 - "${TEMP_DIR}/private.txt" > "${RELEASE_DIR}/singbox-private-ip.json" << 'PY'
import json
import pathlib
import sys

ips = [line.strip() for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
result = {
    "version": 1,
    "rules": [{"ip_cidr": ip} for ip in ips]
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

# RU non-RU domains
python3 - "${RU_NON_RU_NORMALIZED}" > "${RELEASE_DIR}/singbox-ru-non-ru-domains.json" << 'PY'
import json
import pathlib
import sys

rules = []
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    if line.startswith("suffix:"):
        rules.append({"domain_suffix": line.split(":", 1)[1]})
    elif line.startswith("full:"):
        rules.append({"domain": line.split(":", 1)[1]})

result = {
    "version": 1,
    "rules": rules
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

# ========================================
# CLASH (YAML формат для Clash Verge/ClashX/Clash for Windows)
# ========================================
echo "  Clash (YAML)..."

# Antifilter домены
awk 'BEGIN{print "payload:"} {print "  - DOMAIN-SUFFIX,"$0}' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/clash-antifilter-domains.yaml"

# Antifilter IP
awk 'BEGIN{print "payload:"} {print "  - "$0}' "${TEMP_DIR}/merged-antifilter-ip.lst" > "${RELEASE_DIR}/clash-antifilter-ip.yaml"

# AdGuard reject
awk 'BEGIN{print "payload:"} {print "  - "$0}' "${TEMP_DIR}/reject.txt" > "${RELEASE_DIR}/clash-adguard-domains.yaml"

# Loyalsoldier GeoIP - Россия
awk 'BEGIN{print "payload:"} {print "  - "$0}' "${TEMP_DIR}/ru.txt" > "${RELEASE_DIR}/clash-ru-ip.yaml"

# Loyalsoldier GeoIP - Private
awk 'BEGIN{print "payload:"} {print "  - "$0}' "${TEMP_DIR}/private.txt" > "${RELEASE_DIR}/clash-private-ip.yaml"

# RU non-RU domains
awk '
  BEGIN { print "payload:" }
  /^suffix:/ { sub(/^suffix:/, "", $0); print "  - DOMAIN-SUFFIX," $0; next }
  /^full:/   { sub(/^full:/,   "", $0); print "  - DOMAIN," $0; next }
' "${RU_NON_RU_NORMALIZED}" > "${RELEASE_DIR}/clash-ru-non-ru-domains.yaml"

# ========================================
# DNSMASQ формат
# ========================================
echo "  DNSMasq..."
sed -e 's/^/server=\//g' -e 's/$/\/127.0.0.1#5353/g' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/dnsmasq-antifilter-domains.conf"

# ========================================
# ADGUARD HOME формат
# ========================================
echo "  AdGuard Home..."

# AdGuard reject
sed -e 's/DOMAIN-SUFFIX,/||/' -e 's/$/\^/' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/adguard-home-adguard-domains.txt"

# Antifilter домены
sed -e 's/^/||/' -e 's/$/\^/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/adguard-home-antifilter-domains.txt"

# Antifilter IP (merged)
cp "${TEMP_DIR}/merged-antifilter-ip.lst" "${RELEASE_DIR}/adguard-home-antifilter-ip.txt"

# ========================================
# PI-HOLE формат
# ========================================
echo "  Pi-Hole..."

# AdGuard reject
sed -e 's/DOMAIN-SUFFIX,//' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/pihole-adguard-domains.txt"

# Antifilter домены
sort -u "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/pihole-antifilter-domains.txt"

# ========================================
# HOSTS формат
# ========================================
echo "  HOSTS..."

# AdGuard reject
awk '
  /^DOMAIN-SUFFIX,/ {
    sub(/^DOMAIN-SUFFIX,/, "", $0)
    print "0.0.0.0 " $0
    print "::1 " $0
  }
' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/hosts-adguard-hosts.txt"

# Antifilter домены
awk '
  {
    print "0.0.0.0 " $0
    print "::1 " $0
  }
' "${TEMP_DIR}/domains.lst" | sort -u > "${RELEASE_DIR}/hosts-antifilter-hosts.txt"

# ========================================
# PLAIN (для отладки/ручного использования)
# ========================================
echo "  Plain..."
cp "${RU_NON_RU_NORMALIZED}" "${RELEASE_DIR}/plain-ru-non-ru-domains.txt"

echo ""
echo "✅ Готово! Созданные файлы:"
echo ""
echo "=== ИСТОЧНИКИ ==="
echo "  domains.lst                ← community.antifilter.download/list/domains.lst"
echo "  community-ip.lst           ← community.antifilter.download/list/community.lst"
echo "  allyouneed-ip.lst          ← antifilter.download/list/allyouneed.lst"
echo "  reject.txt                 ← Loyalsoldier/surge-rules/refs/heads/release/ruleset/reject.txt"
echo "  ru.txt                     ← Loyalsoldier/geoip/release/text/ru.txt"
echo "  private.txt                ← Loyalsoldier/geoip/release/text/private.txt"
echo "  ru-non-ru-domains.txt      ← local source file"
echo ""
echo "=== MIHOMO/CLASH/SURGE (Surge формат) ==="
echo "  mihomo-antifilter-domains.txt"
echo "  mihomo-antifilter-ip.txt"
echo "  mihomo-adguard-domains.txt"
echo "  mihomo-ru-ip.txt"
echo "  mihomo-private-ip.txt"
echo "  mihomo-ru-non-ru-domains.txt"
echo ""
echo "=== SHADOWROCKET ==="
echo "  shadowrocket-antifilter-domains.txt"
echo "  shadowrocket-antifilter-ip.txt"
echo "  shadowrocket-adguard-domains.txt"
echo "  shadowrocket-ru-ip.txt"
echo "  shadowrocket-private-ip.txt"
echo "  shadowrocket-ru-non-ru-domains.txt"
echo ""
echo "=== SING-BOX ==="
echo "  singbox-antifilter-domains.json"
echo "  singbox-antifilter-ip.json"
echo "  singbox-adguard-domains.json"
echo "  singbox-ru-ip.json"
echo "  singbox-private-ip.json"
echo "  singbox-ru-non-ru-domains.json"
echo ""
echo "=== CLASH YAML ==="
echo "  clash-antifilter-domains.yaml"
echo "  clash-antifilter-ip.yaml"
echo "  clash-adguard-domains.yaml"
echo "  clash-ru-ip.yaml"
echo "  clash-private-ip.yaml"
echo "  clash-ru-non-ru-domains.yaml"
echo ""
echo "=== OTHER ==="
echo "  dnsmasq-antifilter-domains.conf"
echo "  adguard-home-adguard-domains.txt"
echo "  adguard-home-antifilter-domains.txt"
echo "  adguard-home-antifilter-ip.txt"
echo "  pihole-adguard-domains.txt"
echo "  pihole-antifilter-domains.txt"
echo "  hosts-adguard-hosts.txt"
echo "  hosts-antifilter-hosts.txt"
echo "  plain-ru-non-ru-domains.txt"
echo ""
echo "Статистика:"
echo "  Antifilter доменов: $(wc -l < "${RELEASE_DIR}/mihomo-antifilter-domains.txt")"
echo "  Antifilter IP: $(wc -l < "${RELEASE_DIR}/mihomo-antifilter-ip.txt")"
echo "  AdGuard reject: $(wc -l < "${RELEASE_DIR}/mihomo-adguard-domains.txt")"
echo "  Shadowrocket RU IP: $(wc -l < "${RELEASE_DIR}/shadowrocket-ru-ip.txt")"
echo "  Shadowrocket Private IP: $(wc -l < "${RELEASE_DIR}/shadowrocket-private-ip.txt")"
echo "  Mihomo RU IP: $(wc -l < "${RELEASE_DIR}/mihomo-ru-ip.txt")"
echo "  Mihomo Private IP: $(wc -l < "${RELEASE_DIR}/mihomo-private-ip.txt")"
echo "  Clash RU IP: $(grep -c '^  -' "${RELEASE_DIR}/clash-ru-ip.yaml")"
echo "  Clash Private IP: $(grep -c '^  -' "${RELEASE_DIR}/clash-private-ip.yaml")"
echo "  Sing-box RU IP: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-ru-ip.json', encoding='utf-8'))['rules']))")"
echo "  Sing-box Private IP: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-private-ip.json', encoding='utf-8'))['rules']))")"
echo "  Sing-box Antifilter: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-antifilter-domains.json', encoding='utf-8'))['rules']))")"
echo "  Sing-box AdGuard: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-adguard-domains.json', encoding='utf-8'))['rules']))")"
echo "  RU non-RU domains total: $(python3 -c "import json; print(json.load(open('${TEMP_DIR}/ru-non-ru-domains.stats.json', encoding='utf-8'))['total'])")"
echo "  RU non-RU suffix domains: $(python3 -c "import json; print(json.load(open('${TEMP_DIR}/ru-non-ru-domains.stats.json', encoding='utf-8'))['suffix'])")"
echo "  RU non-RU exact hosts: $(python3 -c "import json; print(json.load(open('${TEMP_DIR}/ru-non-ru-domains.stats.json', encoding='utf-8'))['full'])")"
echo "  Clash YAML files: $(find "${RELEASE_DIR}" -name "clash-*.yaml" | wc -l)"
