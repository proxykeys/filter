#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${SCRIPT_DIR}/release"
TEMP_DIR="${SCRIPT_DIR}/temp"

mkdir -p "${RELEASE_DIR}"
mkdir -p "${TEMP_DIR}"

# URL списков
ANTIFILTER_DOMAINS_URL="https://community.antifilter.download/list/domains.lst"
ANTIFILTER_COMMUNITY_IP_URL="https://community.antifilter.download/list/community.lst"
ALLYOUNEED_IP_URL="https://antifilter.download/list/allyouneed.lst"
ADGUARD_REJECT_URL="https://raw.githubusercontent.com/Loyalsoldier/surge-rules/refs/heads/release/ruleset/reject.txt"
# Дополнительные URL для Shadowrocket
RU_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/ru.txt"
PRIVATE_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/private.txt"

echo "Загрузка списков..."

# Загрузка списков
echo "  domains.lst (community.antifilter - домены)..."
curl -s -o "${TEMP_DIR}/domains.lst" "${ANTIFILTER_DOMAINS_URL}"

echo "  community.ip.lst (community.antifilter - IP)..."
curl -s -o "${TEMP_DIR}/community-ip.lst" "${ANTIFILTER_COMMUNITY_IP_URL}"

echo "  allyouneed.ip.lst (antifilter - IP)..."
curl -s -o "${TEMP_DIR}/allyouneed-ip.lst" "${ALLYOUNEED_IP_URL}"

echo "  reject.txt (Loyalsoldier - реклама)..."
curl -s -o "${TEMP_DIR}/reject.txt" "${ADGUARD_REJECT_URL}"

echo "  ru.txt (Loyalsoldier geoip - Россия)..."
curl -s -o "${TEMP_DIR}/ru.txt" "${RU_IP_URL}"

echo "  private.txt (Loyalsoldier geoip - Private)..."
curl -s -o "${TEMP_DIR}/private.txt" "${PRIVATE_IP_URL}"

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

# Loyalsoldier GeoIP - Россия (отдельный файл)
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/ru.txt" > "${RELEASE_DIR}/shadowrocket-ru-ip.txt"

# Loyalsoldier GeoIP - Private (отдельный файл)
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/private.txt" > "${RELEASE_DIR}/shadowrocket-private-ip.txt"

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

# Очистка
rm -rf "${TEMP_DIR}"

echo ""
echo "✅ Готово! Созданные файлы:"
echo ""
echo "=== ИСТОЧНИКИ ==="
echo "  domains.lst          ← community.antifilter.download/list/domains.lst"
echo "  community-ip.lst      ← community.antifilter.download/list/community.lst"
echo "  allyouneed-ip.lst    ← antifilter.download/list/allyouneed.lst"
echo "  reject.txt            ← Loyalsoldier/surge-rules/refs/heads/release/ruleset/reject.txt"
echo "  ru.txt               ← Loyalsoldier/geoip/release/text/ru.txt"
echo "  private.txt           ← Loyalsoldier/geoip/release/text/private.txt"
echo ""
echo "=== MIHOMO/CLASH/SURGE (Surge формат) ==="
echo "  mihomo-antifilter-domains.txt (antifilter домены)"
echo "  mihomo-antifilter-ip.txt (antifilter IP)"
echo "  mihomo-adguard-domains.txt (adguard reject)"
echo ""
echo "=== SHADOWROCKET (Surge формат без ACTION) ==="
echo "  shadowrocket-antifilter-domains.txt (antifilter домены)"
echo "  shadowrocket-antifilter-ip.txt (antifilter IP)"
echo "  shadowrocket-adguard-domains.txt (adguard reject)"
echo "  shadowrocket-ru-ip.txt (российские IP - Loyalsoldier geoip)"
echo "  shadowrocket-private-ip.txt (private IP - Loyalsoldier geoip)"
echo ""
echo "=== SING-BOX (JSON формат) ==="
echo "  singbox-antifilter-domains.json (antifilter домены)"
echo "  singbox-antifilter-ip.json (antifilter IP)"
echo "  singbox-adguard-domains.json (adguard reject)"
echo ""
echo "=== CLASH (YAML формат для Clash Verge/ClashX/Clash for Windows) ==="
echo "  clash-antifilter-domains.yaml (antifilter домены)"
echo "  clash-antifilter-ip.yaml (antifilter IP)"
echo "  clash-adguard-domains.yaml (adguard reject)"
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
echo "Статистика:"
echo "  Antifilter доменов: $(cat "${RELEASE_DIR}/mihomo-antifilter-domains.txt" | wc -l)"
echo "  Antifilter IP: $(cat "${RELEASE_DIR}/mihomo-antifilter-ip.txt" | wc -l)"
echo "  AdGuard reject: $(cat "${RELEASE_DIR}/mihomo-adguard-domains.txt" | wc -l)"
echo "  Shadowrocket RU IP: $(cat "${RELEASE_DIR}/shadowrocket-ru-ip.txt" | wc -l)"
echo "  Shadowrocket Private IP: $(cat "${RELEASE_DIR}/shadowrocket-private-ip.txt" | wc -l)"
echo "  Sing-box Antifilter: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-antifilter-domains.json'))['rules']))")"
echo "  Sing-box AdGuard: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-adguard-domains.json'))['rules']))")"
echo "  Clash YAML файлы: $(find "${RELEASE_DIR}" -name "clash-*.yaml" | wc -l)"
