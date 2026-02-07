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

echo "Конвертация..."

# ========================================
# MIHOMO/CLASH/SURGE (без ACTION)
# ========================================
echo "  Mihomo/Clash/Surge..."

# Antifilter домены
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/mihomo-antifilter-domains.txt"

# Antifilter IP
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | sed -e 's/^/IP-CIDR,/' > "${RELEASE_DIR}/mihomo-antifilter-ip.txt"

# AdGuard reject
cp "${TEMP_DIR}/reject.txt" "${RELEASE_DIR}/mihomo-adguard-domains.txt"

# ========================================
# SHADOWROCKET (с ACTION)
# ========================================
echo "  Shadowrocket..."

# Antifilter домены
sed -e 's/^/DOMAIN-SUFFIX,/' -e 's/$/,PROXY/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/shadowrocket-antifilter-domains.txt"

# Antifilter IP
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | sed -e 's/^/IP-CIDR,/' -e 's/$/,PROXY/' > "${RELEASE_DIR}/shadowrocket-antifilter-ip.txt"

# AdGuard reject
sed -e 's/$/,REJECT/' "${TEMP_DIR}/reject.txt" > "${RELEASE_DIR}/shadowrocket-adguard-domains.txt"

# ========================================
# SING-BOX (JSON)
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
# DNSMASQ
# ========================================
echo "  DNSMasq..."
sed -e 's/^/server=\//g' -e 's/$/\/127.0.0.1#5353/g' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/dnsmasq-antifilter-domains.conf"

# ========================================
# ADGUARD HOME
# ========================================
echo "  AdGuard Home..."

# AdGuard reject
sed -e 's/DOMAIN-SUFFIX,/||/' -e 's/$/\^/' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/adguard-home-adguard-domains.txt"

# Antifilter домены
sed -e 's/^/||/' -e 's/$/\^/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/adguard-home-antifilter-domains.txt"

# Antifilter IP
cp "${TEMP_DIR}/community-ip.lst" "${RELEASE_DIR}/adguard-home-antifilter-ip.txt"

# ========================================
# PI-HOLE
# ========================================
echo "  Pi-Hole..."

# AdGuard reject
sed -e 's/DOMAIN-SUFFIX,//' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/pihole-adguard-domains.txt"

# Antifilter домены
sed -e 's/DOMAIN-SUFFIX,//' "${TEMP_DIR}/domains.lst" | sort -u > "${RELEASE_DIR}/pihole-antifilter-domains.txt"

# ========================================
# HOSTS
# ========================================
echo "  HOSTS..."

# AdGuard reject
awk '{if ($0 ~ /^DOMAIN-SUFFIX,/) {sub(/DOMAIN-SUFFIX,/, "", $0); print "0.0.0.0 " $0 "\n::1 " $0}}' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/hosts-adguard-hosts.txt"

# Antifilter домены
awk '{print "0.0.0.0 " $0 "\n::1 " $0}' "${TEMP_DIR}/domains.lst" | sort -u > "${RELEASE_DIR}/hosts-antifilter-hosts.txt"

rm -rf "${TEMP_DIR}"

echo ""
echo "✅ Готово! Созданные файлы:"
echo ""
echo "=== ИСТОЧНИКИ ==="
echo "  domains.lst          ← community.antifilter.download/list/domains.lst"
echo "  community-ip.lst      ← community.antifilter.download/list/community.lst"
echo "  allyouneed-ip.lst    ← antifilter.download/list/allyouneed.lst"
echo "  reject.txt            ← Loyalsoldier/surge-rules/refs/heads/release/ruleset/reject.txt"
echo ""
echo "=== MIHOMO/CLASH/SURGE ==="
echo "  mihomo-antifilter-domains.txt (antifilter домены)"
echo "  mihomo-antifilter-ip.txt (antifilter IP)"
echo "  mihomo-adguard-domains.txt (adguard reject)"
echo ""
echo "=== SHADOWROCKET ==="
echo "  shadowrocket-antifilter-domains.txt (antifilter домены)"
echo "  shadowrocket-antifilter-ip.txt (antifilter IP)"
echo "  shadowrocket-adguard-domains.txt (adguard reject)"
echo ""
echo "=== SING-BOX ==="
echo "  singbox-antifilter-domains.json (antifilter домены)"
echo "  singbox-antifilter-ip.json (antifilter IP)"
echo "  singbox-adguard-domains.json (adguard reject)"
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
echo "  Sing-box Antifilter: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-antifilter-domains.json'))['rules']))")"
echo "  Sing-box AdGuard: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-adguard-domains.json'))['rules']))")"
