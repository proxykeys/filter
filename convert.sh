#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${SCRIPT_DIR}/release"
TEMP_DIR="${SCRIPT_DIR}/temp"
RU_NON_RU_SOURCE="${SCRIPT_DIR}/ru-non-ru-domains.txt"

mkdir -p "${RELEASE_DIR}"
mkdir -p "${TEMP_DIR}"

if [ ! -f "${RU_NON_RU_SOURCE}" ]; then
  echo "❌ Не найден файл: ${RU_NON_RU_SOURCE}"
  exit 1
fi

# URL списков
ANTIFILTER_DOMAINS_URL="https://community.antifilter.download/list/domains.lst"
ANTIFILTER_COMMUNITY_IP_URL="https://community.antifilter.download/list/community.lst"
ALLYOUNEED_IP_URL="https://antifilter.download/list/allyouneed.lst"
ADGUARD_REJECT_URL="https://raw.githubusercontent.com/Loyalsoldier/surge-rules/refs/heads/release/ruleset/reject.txt"
RU_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/ru.txt"
PRIVATE_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/private.txt"

DOMAIN_LIST_COMMUNITY_REPO="https://github.com/v2fly/domain-list-community.git"
DOMAIN_LIST_CUSTOM_REPO="https://github.com/runetfreedom/domain-list-custom.git"

echo "Загрузка списков..."

# Загрузка списков
echo "  domains.lst (community.antifilter - домены)..."
curl -fsSL -o "${TEMP_DIR}/domains.lst" "${ANTIFILTER_DOMAINS_URL}"

echo "  community.ip.lst (community.antifilter - IP)..."
curl -fsSL -o "${TEMP_DIR}/community-ip.lst" "${ANTIFILTER_COMMUNITY_IP_URL}"

echo "  allyouneed.ip.lst (antifilter - IP)..."
curl -fsSL -o "${TEMP_DIR}/allyouneed-ip.lst" "${ALLYOUNEED_IP_URL}"

echo "  reject.txt (Loyalsoldier - реклама)..."
curl -fsSL -o "${TEMP_DIR}/reject.txt" "${ADGUARD_REJECT_URL}"

echo "  ru.txt (Loyalsoldier geoip - Россия)..."
curl -fsSL -o "${TEMP_DIR}/ru.txt" "${RU_IP_URL}"

echo "  private.txt (Loyalsoldier geoip - Private)..."
curl -fsSL -o "${TEMP_DIR}/private.txt" "${PRIVATE_IP_URL}"

echo "Подготовка ru-non-ru-domains..."
awk '
{
  sub(/\r$/, "", $0)
  if ($0 ~ /^[[:space:]]*$/) next
  if ($0 ~ /^[[:space:]]*#/) next
  print tolower($0)
}
' "${RU_NON_RU_SOURCE}" | awk '!seen[$0]++' > "${TEMP_DIR}/ru-non-ru-domains.lst"

echo "Подготовка geosite source для Shadowrocket category-ru/category-gov-ru..."

echo "  domain-list-community..."
git clone --depth=1 "${DOMAIN_LIST_COMMUNITY_REPO}" "${TEMP_DIR}/domain-list-community"

echo "  domain-list-custom..."
git clone --depth=1 "${DOMAIN_LIST_CUSTOM_REPO}" "${TEMP_DIR}/domain-list-custom"

echo "  Сборка plaintext export category-ru/category-gov-ru..."
mkdir -p "${TEMP_DIR}/domain-export"
(
  cd "${TEMP_DIR}/domain-list-custom"
  go mod download
  go run ./ \
    --exportlists=category-ru,category-gov-ru \
    --datapath="${TEMP_DIR}/domain-list-community/data" \
    --outputpath="${TEMP_DIR}/domain-export"
)

echo "Конвертация..."

# ========================================
# MIHOMO/CLASH/SURGE (Surge формат без ACTION)
# ========================================
echo "  Mihomo/Clash/Surge..."

# Antifilter домены
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/mihomo-antifilter-domains.txt"

# Antifilter IP
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | sed -e 's/^/IP-CIDR,/' > "${RELEASE_DIR}/mihomo-antifilter-ip.txt"

# AdGuard reject
cp "${TEMP_DIR}/reject.txt" "${RELEASE_DIR}/mihomo-adguard-domains.txt"

# Loyalsoldier GeoIP - Россия
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/ru.txt" > "${RELEASE_DIR}/mihomo-ru-ip.txt"

# Loyalsoldier GeoIP - Private
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/private.txt" > "${RELEASE_DIR}/mihomo-private-ip.txt"

# RU non-RU domains
awk '
  /^full:/ { sub(/^full:/, "", $0); print "DOMAIN," $0; next }
          { print "DOMAIN-SUFFIX," $0 }
' "${TEMP_DIR}/ru-non-ru-domains.lst" > "${RELEASE_DIR}/mihomo-ru-non-ru-domains.txt"

# ========================================
# SHADOWROCKET (Surge формат без ACTION)
# ========================================
echo "  Shadowrocket..."

# Antifilter домены
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/shadowrocket-antifilter-domains.txt"

# Antifilter IP
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | sed -e 's/^/IP-CIDR,/' > "${RELEASE_DIR}/shadowrocket-antifilter-ip.txt"

# AdGuard reject (чистый формат без DOMAIN-SUFFIX,)
sed -e 's/^DOMAIN-SUFFIX,//' "${TEMP_DIR}/reject.txt" > "${RELEASE_DIR}/shadowrocket-adguard-domains.txt"

# Loyalsoldier GeoIP - Россия
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/ru.txt" > "${RELEASE_DIR}/shadowrocket-ru-ip.txt"

# Loyalsoldier GeoIP - Private
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/private.txt" > "${RELEASE_DIR}/shadowrocket-private-ip.txt"

# category-ru / category-gov-ru из geosite source
if grep -q '^regexp:' "${TEMP_DIR}/domain-export/category-ru.txt"; then
  echo "❌ regexp rules found in category-ru.txt; Shadowrocket export is not implemented for regexp"
  exit 1
fi

if grep -q '^regexp:' "${TEMP_DIR}/domain-export/category-gov-ru.txt"; then
  echo "❌ regexp rules found in category-gov-ru.txt; Shadowrocket export is not implemented for regexp"
  exit 1
fi

awk '
  /^domain:/  { sub(/^domain:/, "", $0); print "DOMAIN-SUFFIX," $0; next }
  /^full:/    { sub(/^full:/, "", $0); print "DOMAIN," $0; next }
  /^keyword:/ { sub(/^keyword:/, "", $0); print "DOMAIN-KEYWORD," $0; next }
' "${TEMP_DIR}/domain-export/category-ru.txt" | awk '!seen[$0]++' > "${RELEASE_DIR}/shadowrocket-category-ru-domains.txt"

awk '
  /^domain:/  { sub(/^domain:/, "", $0); print "DOMAIN-SUFFIX," $0; next }
  /^full:/    { sub(/^full:/, "", $0); print "DOMAIN," $0; next }
  /^keyword:/ { sub(/^keyword:/, "", $0); print "DOMAIN-KEYWORD," $0; next }
' "${TEMP_DIR}/domain-export/category-gov-ru.txt" | awk '!seen[$0]++' > "${RELEASE_DIR}/shadowrocket-category-gov-ru-domains.txt"

# RU non-RU domains
awk '
  /^full:/ { sub(/^full:/, "", $0); print "DOMAIN," $0; next }
          { print "DOMAIN-SUFFIX," $0 }
' "${TEMP_DIR}/ru-non-ru-domains.lst" > "${RELEASE_DIR}/shadowrocket-ru-non-ru-domains.txt"

# ========================================
# SING-BOX (JSON через Python)
# ========================================
echo "  Sing-box (Python)..."

# Antifilter домены
cat "${TEMP_DIR}/domains.lst" | python3 -c "
import sys, json

domains = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'domain_suffix': d} for d in domains]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-antifilter-domains.json"

# Antifilter IP
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | python3 -c "
import sys, json

ips = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'ip_cidr': ip} for ip in ips]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-antifilter-ip.json"

# AdGuard reject
cat "${TEMP_DIR}/reject.txt" | sed -e 's/^DOMAIN-SUFFIX,//' | sort -u | python3 -c "
import sys, json

domains = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'domain_suffix': d} for d in domains]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-adguard-domains.json"

# Loyalsoldier GeoIP - Россия
cat "${TEMP_DIR}/ru.txt" | python3 -c "
import sys, json

ips = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'ip_cidr': ip} for ip in ips]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-ru-ip.json"

# Loyalsoldier GeoIP - Private
cat "${TEMP_DIR}/private.txt" | python3 -c "
import sys, json

ips = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'ip_cidr': ip} for ip in ips]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-private-ip.json"

# RU non-RU domains
cat "${TEMP_DIR}/ru-non-ru-domains.lst" | python3 -c "
import sys, json

rules = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith('full:'):
        rules.append({'domain': line[5:]})
    else:
        rules.append({'domain_suffix': line})

result = {
    'version': 1,
    'rules': rules
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-ru-non-ru-domains.json"

# ========================================
# CLASH (YAML формат для Clash Verge/ClashX/Clash for Windows)
# ========================================
echo "  Clash (YAML)..."

# Antifilter домены (с префиксом)
cat "${TEMP_DIR}/domains.lst" | awk 'BEGIN{print "payload:"} {print "  - DOMAIN-SUFFIX,"$0}' > "${RELEASE_DIR}/clash-antifilter-domains.yaml"

# Antifilter IP (БЕЗ префикса!)
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | awk 'BEGIN{print "payload:"} {print "  - "$0}' > "${RELEASE_DIR}/clash-antifilter-ip.yaml"

# AdGuard reject (с префиксом)
cat "${TEMP_DIR}/reject.txt" | awk 'BEGIN{print "payload:"} {print "  - "$0}' > "${RELEASE_DIR}/clash-adguard-domains.yaml"

# Loyalsoldier GeoIP - Россия (БЕЗ префикса!)
cat "${TEMP_DIR}/ru.txt" | awk 'BEGIN{print "payload:"} {print "  - "$0}' > "${RELEASE_DIR}/clash-ru-ip.yaml"

# Loyalsoldier GeoIP - Private (БЕЗ префикса!)
cat "${TEMP_DIR}/private.txt" | awk 'BEGIN{print "payload:"} {print "  - "$0}' > "${RELEASE_DIR}/clash-private-ip.yaml"

# RU non-RU domains
awk '
  BEGIN { print "payload:" }
  /^full:/ { sub(/^full:/, "", $0); print "  - DOMAIN," $0; next }
          { print "  - DOMAIN-SUFFIX," $0 }
' "${TEMP_DIR}/ru-non-ru-domains.lst" > "${RELEASE_DIR}/clash-ru-non-ru-domains.yaml"

# ========================================
# DNSMASQ формат
# ========================================
echo "  DNSMasq..."
sed -e 's/^/server=\//g' -e 's/$/\/127.0.0.1#5353/g' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/dnsmasq-antifilter-domains.conf"

# ========================================
# ADGUARD HOME формат
# ========================================
echo "  AdGuard Home..."

# AdGuard reject (блокировка рекламы)
sed -e 's/DOMAIN-SUFFIX,/||/' -e 's/$/\^/' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/adguard-home-adguard-domains.txt"

# Antifilter домены (антифильтр через прокси)
sed -e 's/^/||/' -e 's/$/\^/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/adguard-home-antifilter-domains.txt"

# Antifilter IP
cp "${TEMP_DIR}/community-ip.lst" "${RELEASE_DIR}/adguard-home-antifilter-ip.txt"

# ========================================
# PI-HOLE формат
# ========================================
echo "  Pi-Hole..."

# AdGuard reject (блокировка рекламы)
sed -e 's/DOMAIN-SUFFIX,//' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/pihole-adguard-domains.txt"

# Antifilter домены (антифильтр через прокси)
sed -e 's/DOMAIN-SUFFIX,//' "${TEMP_DIR}/domains.lst" | sort -u > "${RELEASE_DIR}/pihole-antifilter-domains.txt"

# ========================================
# HOSTS формат
# ========================================
echo "  HOSTS..."

# AdGuard reject (блокировка рекламы)
awk '{if ($0 ~ /^DOMAIN-SUFFIX,/) {sub(/DOMAIN-SUFFIX,/, "", $0); print "0.0.0.0 " $0 "\n::1 " $0}}' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/hosts-adguard-hosts.txt"

# Antifilter домены (антифильтр через прокси)
awk '{print "0.0.0.0 " $0 "\n::1 " $0}' "${TEMP_DIR}/domains.lst" | sort -u > "${RELEASE_DIR}/hosts-antifilter-hosts.txt"

# ========================================
# PLAIN
# ========================================
echo "  Plain..."
cp "${TEMP_DIR}/ru-non-ru-domains.lst" "${RELEASE_DIR}/plain-ru-non-ru-domains.txt"

# Очистка
rm -rf "${TEMP_DIR}"

echo ""
echo "✅ Готово! Созданные файлы:"
echo ""
echo "=== ИСТОЧНИКИ ==="
echo "  domains.lst                ← community.antifilter.download/list/domains.lst"
echo "  community-ip.lst           ← community.antifilter.download/list/community.lst"
echo "  allyouneed-ip.lst          ← antifilter.download/list/allyouneed.lst"
echo "  reject.txt                ← Loyalsoldier/surge-rules/refs/heads/release/ruleset/reject.txt"
echo "  ru.txt                    ← Loyalsoldier/geoip/release/text/ru.txt"
echo "  private.txt               ← Loyalsoldier/geoip/release/text/private.txt"
echo "  ru-non-ru-domains.txt     ← local source file"
echo ""
echo "=== MIHOMO/CLASH/SURGE (Surge формат) ==="
echo "  mihomo-antifilter-domains.txt (antifilter домены)"
echo "  mihomo-antifilter-ip.txt (antifilter IP)"
echo "  mihomo-adguard-domains.txt (adguard reject)"
echo "  mihomo-ru-ip.txt (российские IP - Loyalsoldier geoip)"
echo "  mihomo-private-ip.txt (private IP - Loyalsoldier geoip)"
echo "  mihomo-ru-non-ru-domains.txt (российские non-.ru домены)"
echo ""
echo "=== SHADOWROCKET (Surge формат без ACTION) ==="
echo "  shadowrocket-antifilter-domains.txt (antifilter домены)"
echo "  shadowrocket-antifilter-ip.txt (antifilter IP)"
echo "  shadowrocket-adguard-domains.txt (adguard reject)"
echo "  shadowrocket-ru-ip.txt (российские IP - Loyalsoldier geoip)"
echo "  shadowrocket-private-ip.txt (private IP - Loyalsoldier geoip)"
echo "  shadowrocket-category-ru-domains.txt (geosite category-ru)"
echo "  shadowrocket-category-gov-ru-domains.txt (geosite category-gov-ru)"
echo "  shadowrocket-ru-non-ru-domains.txt (российские non-.ru домены)"
echo ""
echo "=== SING-BOX (JSON формат) ==="
echo "  singbox-antifilter-domains.json (antifilter домены)"
echo "  singbox-antifilter-ip.json (antifilter IP)"
echo "  singbox-adguard-domains.json (adguard reject)"
echo "  singbox-ru-ip.json (российские IP - Loyalsoldier geoip)"
echo "  singbox-private-ip.json (private IP - Loyalsoldier geoip)"
echo "  singbox-ru-non-ru-domains.json (российские non-.ru домены)"
echo ""
echo "=== CLASH (YAML формат для Clash Verge/ClashX/Clash for Windows) ==="
echo "  clash-antifilter-domains.yaml (antifilter домены)"
echo "  clash-antifilter-ip.yaml (antifilter IP)"
echo "  clash-adguard-domains.yaml (adguard reject)"
echo "  clash-ru-ip.yaml (российские IP - Loyalsoldier geoip)"
echo "  clash-private-ip.yaml (private IP - Loyalsoldier geoip)"
echo "  clash-ru-non-ru-domains.yaml (российские non-.ru домены)"
echo ""
echo "=== DNSMASQ ==="
echo "  dnsmasq-antifilter-domains.conf"
echo ""
echo "=== ADGUARD HOME ==="
echo "  adguard-home-adguard-domains.txt (adguard reject)"
echo "  adguard-home-antifilter-domains.txt (antifilter домены)"
echo "  adguard-home-antifilter-ip.txt (antifilter IP)"
echo ""
echo "=== PI-HOLE ==="
echo "  pihole-adguard-domains.txt (adguard reject)"
echo "  pihole-antifilter-domains.txt (antifilter домены)"
echo ""
echo "=== HOSTS ==="
echo "  hosts-adguard-hosts.txt (adguard reject)"
echo "  hosts-antifilter-hosts.txt (antifilter домены)"
echo ""
echo "=== PLAIN ==="
echo "  plain-ru-non-ru-domains.txt"
echo ""
echo "Статистика:"
echo "  Antifilter доменов: $(cat "${RELEASE_DIR}/mihomo-antifilter-domains.txt" | wc -l)"
echo "  Antifilter IP: $(cat "${RELEASE_DIR}/mihomo-antifilter-ip.txt" | wc -l)"
echo "  AdGuard reject: $(cat "${RELEASE_DIR}/mihomo-adguard-domains.txt" | wc -l)"
echo "  Shadowrocket RU IP: $(cat "${RELEASE_DIR}/shadowrocket-ru-ip.txt" | wc -l)"
echo "  Shadowrocket Private IP: $(cat "${RELEASE_DIR}/shadowrocket-private-ip.txt" | wc -l)"
echo "  Shadowrocket category-ru: $(cat "${RELEASE_DIR}/shadowrocket-category-ru-domains.txt" | wc -l)"
echo "  Shadowrocket category-gov-ru: $(cat "${RELEASE_DIR}/shadowrocket-category-gov-ru-domains.txt" | wc -l)"
echo "  Shadowrocket RU non-RU: $(cat "${RELEASE_DIR}/shadowrocket-ru-non-ru-domains.txt" | wc -l)"
echo "  Mihomo RU IP: $(cat "${RELEASE_DIR}/mihomo-ru-ip.txt" | wc -l)"
echo "  Mihomo Private IP: $(cat "${RELEASE_DIR}/mihomo-private-ip.txt" | wc -l)"
echo "  Mihomo RU non-RU: $(cat "${RELEASE_DIR}/mihomo-ru-non-ru-domains.txt" | wc -l)"
echo "  Clash RU IP: $(cat "${RELEASE_DIR}/clash-ru-ip.yaml" | grep -c "^  -")"
echo "  Clash Private IP: $(cat "${RELEASE_DIR}/clash-private-ip.yaml" | grep -c "^  -")"
echo "  Clash RU non-RU: $(cat "${RELEASE_DIR}/clash-ru-non-ru-domains.yaml" | grep -c "^  -")"
echo "  Sing-box RU IP: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-ru-ip.json'))['rules']))")"
echo "  Sing-box Private IP: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-private-ip.json'))['rules']))")"
echo "  Sing-box Antifilter: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-antifilter-domains.json'))['rules']))")"
echo "  Sing-box AdGuard: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-adguard-domains.json'))['rules']))")"
echo "  Sing-box RU non-RU: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-ru-non-ru-domains.json'))['rules']))")"
echo "  Clash YAML файлы: $(find "${RELEASE_DIR}" -name "clash-*.yaml" | wc -l)"
