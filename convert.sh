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

echo "Загрузка списков..."

# Загрузка списков
echo "  domains.lst (community.antifilter - домены)..."
curl -s -o "${TEMP_DIR}/domains.lst" "${ANTIFILTER_DOMAINS_URL}"

echo "  community.ip.lst (community.antifilter - IP)..."
curl -s -o "${TEMP_DIR}/community-ip.lst" "${ANTIFILTER_COMMUNITY_IP_URL}"

echo "  allyouneed.ip.lst (antifilter - IP)..."
curl -s -o "${TEMP_DIR}/allyouneed-ip.lst" "${ALLYOUNEED_IP_URL}"

echo "Конвертация..."

# ========================================
# SURGE/CLASH/MIHOMO Rule Providers (без ACTION)
# ========================================
echo "  Surge/Clash/Mihomo..."

# Домены (единственный источник)
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/surge-domains.txt"
sed -e 's/^/DOMAIN-SUFFIX,/' "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/surge-all-domains.txt"

# IP (community + allyouneed)
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/community-ip.lst" > "${RELEASE_DIR}/ipcidr-community.txt"
sed -e 's/^/IP-CIDR,/' "${TEMP_DIR}/allyouneed-ip.lst" > "${RELEASE_DIR}/ipcidr-allyouneed.txt"
cat "${TEMP_DIR}/community-ip.lst" "${TEMP_DIR}/allyouneed-ip.lst" | sort -u | sed -e 's/^/IP-CIDR,/' > "${RELEASE_DIR}/ipcidr-all.txt"

# ========================================
# SHADOWROCKET/SURGE/QUANTUMULT X/LOON (с ACTION)
# ========================================
echo "  Shadowrocket..."

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

# ========================================
# DNSMASQ формат
# ========================================
echo "  DNSMasq..."
while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    echo "server=/$domain/127.0.0.1#5353"
done < "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/dnsmasq-domains.conf"

# ========================================
# ADGUARD формат
# ========================================
echo "  AdGuard..."
while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    echo "||$domain^"
done < "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/adguard-domains.txt"

while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    echo "$ip"
done < "${TEMP_DIR}/community-ip.lst" > "${RELEASE_DIR}/adguard-ip.txt"

# ========================================
# PI-HOLE формат
# ========================================
echo "  Pi-Hole..."
while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    echo "$domain"
done < "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/pihole-domains.txt"

# ========================================
# HOSTS формат
# ========================================
echo "  HOSTS..."
while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    echo "0.0.0.0 $domain"
    echo "::1 $domain"
done < "${TEMP_DIR}/domains.lst" > "${RELEASE_DIR}/hosts-domains.txt"

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
echo ""
echo "=== SURGE/CLASH/MIHOMO ==="
echo "  release/surge-all-domains.txt (domains only)"
echo "  release/ipcidr-all.txt (community-ip + allyouneed-ip)"
echo ""
echo "=== SHADOWROCKET ==="
echo "  release/shadowrocket-all-domains.txt (domains only)"
echo "  release/shadowrocket-all-ip.txt (community-ip + allyouneed-ip)"
echo ""
echo "=== SING-BOX ==="
echo "  release/singbox-domains.json (domains only)"
echo "  release/singbox-ip.json (community-ip + allyouneed-ip)"
echo ""
echo "=== DNSMASQ ==="
echo "  release/dnsmasq-domains.conf"
echo ""
echo "=== ADGUARD ==="
echo "  release/adguard-domains.txt"
echo "  release/adguard-ip.txt"
echo ""
echo "=== PI-HOLE ==="
echo "  release/pihole-domains.txt"
echo ""
echo "=== HOSTS ==="
echo "  release/hosts-domains.txt"
echo ""
echo "=== Совместимость ==="
echo "  release/allyouneed.txt = ipcidr-all.txt"
echo "  release/allyouneed-sr.txt = shadowrocket-all-ip.txt"
echo "  release/community.txt = ipcidr-community.txt"
echo "  release/community-sr.txt = shadowrocket-community-ip.txt"
echo ""
echo "Статистика:"
echo "  Доменов: $(cat "${RELEASE_DIR}/surge-all-domains.txt" | wc -l)"
echo "  IP (community): $(cat "${RELEASE_DIR}/ipcidr-community.txt" | wc -l)"
echo "  IP (allyouneed): $(cat "${RELEASE_DIR}/ipcidr-allyouneed.txt" | wc -l)"
echo "  IP (всего): $(cat "${RELEASE_DIR}/ipcidr-all.txt" | wc -l)"