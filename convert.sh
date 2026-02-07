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
# SURGE/CLASH/MIHOMO Rule Providers (без ACTION)
# ========================================
echo "  Surge/Clash/Mihomo..."

# Домены
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/surge-domains.txt"
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/surge-all-domains.txt"

# IP
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/community-ip.lst" > "${RELEASE_DIR}/ipcidr-community.txt"
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/allyouneed-ip.lst" > "${RELEASE_DIR}/ipcidr-allyouneed.txt"
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | sed -e 's/^/IP-CIDR,/' > "${RELEASE_DIR}/ipcidr-all.txt"

# AdGuard reject (просто копируем для Mihomo/Clash)
cp "${TEMP_DIR}/reject.txt" "${RELEASE_DIR}/surge-adguard-reject.txt"

# ========================================
# SHADOWROCKET/SURGE/QUANTUMULT X/LOON (с ACTION)
# ========================================
echo "  Shadowrocket..."

# AdGuard reject (уже содержит DOMAIN-SUFFIX,)
sed -e 's/$/,REJECT/' "${TEMP_DIR}/reject.txt" > "${RELEASE_DIR}/shadowrocket-adguard-reject.txt"

# Домены
sed -e 's/^/DOMAIN-SUFFIX,/' -e 's/$/,PROXY/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/shadowrocket-domains.txt"
sed -e 's/^/DOMAIN-SUFFIX,/' -e 's/$/,PROXY/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/shadowrocket-all-domains.txt"

# IP
sed -e 's/^/IP-CIDR,/' -e 's/$/,PROXY/' "${TEMP_DIR}/community-ip.lst" > "${RELEASE_DIR}/shadowrocket-community-ip.txt"
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | sed -e 's/^/IP-CIDR,/' -e 's/$/,PROXY/' > "${RELEASE_DIR}/shadowrocket-all-ip.txt"

# ========================================
# SING-BOX rule-set (JSON через Python)
# ========================================
echo "  Sing-box (Python)..."

# Генерация JSON для доменов
cat "${TEMP_DIR}/domains.lst" | python3 -c "
import sys, json

domains = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'domain_suffix': d} for d in domains]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-domains.json"

# Генерация JSON для IP
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | python3 -c "
import sys, json

ips = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'ip_cidr': ip} for ip in ips]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-ip.json"

# Генерация JSON для AdGuard reject
cat "${TEMP_DIR}/reject.txt" | sed -e 's/^DOMAIN-SUFFIX,//' | sort -u | python3 -c "
import sys, json

domains = [line.strip() for line in sys.stdin if line.strip()]

result = {
    'version': 1,
    'rules': [{'domain_suffix': d} for d in domains]
}

print(json.dumps(result, indent=2))
" > "${RELEASE_DIR}/singbox-adguard.json"

# ========================================
# DNSMASQ формат
# ========================================
echo "  DNSMasq..."
sed -e 's/^/server=\//g' -e 's/$/\/127.0.0.1#5353/g' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/dnsmasq-domains.conf"

# ========================================
# ADGUARD формат
# ========================================
echo "  AdGuard..."

# AdGuard reject (простой sed)
sed -e 's/DOMAIN-SUFFIX,/||/' -e 's/$/\^/' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/adguard-reject.txt"

# AdGuard antifilter
sed -e 's/^/||/' -e 's/$/\^/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/adguard-domains.txt"

# AdGuard IP
cp "${TEMP_DIR}/community-ip.lst" "${RELEASE_DIR}/adguard-ip.txt"

# ========================================
# PI-HOLE формат
# ========================================
echo "  Pi-Hole..."

# Pi-Hole reject (простой sed)
sed -e 's/DOMAIN-SUFFIX,//' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/pihole-reject.txt"

# Pi-Hole antifilter
sed -e 's/^//' "${TEMP_DIR}/domains.lst" | sort -u > "${RELEASE_DIR}/pihole-domains.txt"

# ========================================
# HOSTS формат
# ========================================
echo "  HOSTS..."

# HOSTS reject (оптимизировано через awk)
awk '{if ($0 ~ /^DOMAIN-SUFFIX,/) {sub(/DOMAIN-SUFFIX,/, "", $0); print "0.0.0.0 " $0 "\n::1 " $0}}' "${TEMP_DIR}/reject.txt" | sort -u > "${RELEASE_DIR}/hosts-reject.txt"

# HOSTS antifilter (оптимизировано через awk)
awk '{print "0.0.0.0 " $0 "\n::1 " $0}' "${TEMP_DIR}/domains.lst" | sort -u > "${RELEASE_DIR}/hosts-domains.txt"

# ========================================
# ОБРАТНАЯ СОВМЕСТИМОСТЬ
# ========================================
echo "  Обратная совместимость..."
cp "${RELEASE_DIR}/ipcidr-all.txt" "${RELEASE_DIR}/allyouneed.txt"
cp "${RELEASE_DIR}/shadowrocket-all-ip.txt" "${RELEASE_DIR}/allyouneed-sr.txt"
cp "${RELEASE_DIR}/ipcidr-community.txt" "${RELEASE_DIR}/community.txt"
cp "${RELEASE_DIR}/shadowrocket-community-ip.txt" "${RELEASE_DIR}/community-sr.txt"

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
echo "=== SURGE/CLASH/MIHOMO ==="
echo "  release/surge-all-domains.txt (antifilter)"
echo "  release/ipcidr-all.txt (antifilter IP)"
echo "  release/surge-adguard-reject.txt (AdGuard - БЛОКИРОВКА)"
echo ""
echo "=== SHADOWROCKET ==="
echo "  release/shadowrocket-all-domains.txt (antifilter)"
echo "  release/shadowrocket-all-ip.txt (antifilter IP)"
echo "  release/shadowrocket-adguard-reject.txt (AdGuard - БЛОКИРОВКА)"
echo ""
echo "=== SING-BOX ==="
echo "  release/singbox-domains.json (antifilter)"
echo "  release/singbox-ip.json (antifilter IP)"
echo "  release/singbox-adguard.json (AdGuard - БЛОКИРОВКА)"
echo ""
echo "=== DNSMASQ ==="
echo "  release/dnsmasq-domains.conf"
echo ""
echo "=== ADGUARD ==="
echo "  release/adguard-reject.txt (БЛОКИРОВКА)"
echo "  release/adguard-domains.txt"
echo "  release/adguard-ip.txt"
echo ""
echo "=== PI-HOLE ==="
echo "  release/pihole-reject.txt (БЛОКИРОВКА)"
echo "  release/pihole-domains.txt"
echo ""
echo "=== HOSTS ==="
echo "  release/hosts-reject.txt (БЛОКИРОВКА)"
echo "  release/hosts-domains.txt"
echo ""
echo "=== Совместимость ==="
echo "  release/allyouneed.txt = ipcidr-all.txt"
echo "  release/allyouneed-sr.txt = shadowrocket-all-ip.txt"
echo "  release/community.txt = ipcidr-community.txt"
echo "  release/community-sr.txt = shadowrocket-community-ip.txt"
echo ""
echo "Статистика:"
echo "  Antifilter доменов: $(cat "${RELEASE_DIR}/surge-all-domains.txt" | wc -l)"
echo "  Antifilter IP: $(cat "${RELEASE_DIR}/ipcidr-all.txt" | wc -l)"
echo "  AdGuard reject: $(cat "${RELEASE_DIR}/surge-adguard-reject.txt" | wc -l)"
echo "  Sing-box AdGuard: $(python3 -c "import json; print(len(json.load(open('${RELEASE_DIR}/singbox-adguard.json'))['rules']))")"
