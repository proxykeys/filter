#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${ROOT_DIR}/release"
TEMP_DIR="$(mktemp -d "${ROOT_DIR}/.tmp.convert.XXXXXX")"

trap 'rm -rf "${TEMP_DIR}"' EXIT

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Missing command: $1" >&2
    exit 1
  }
}

log() {
  echo "[$(date '+%F %T')] $*"
}

fetch() {
  local url="$1"
  local out="$2"
  curl --retry 5 --retry-delay 2 --retry-all-errors -fsSL "$url" -o "$out"
}

for cmd in curl git go python3 awk sed sort grep; do
  need "$cmd"
done

RU_NON_RU_SOURCE="${ROOT_DIR}/ru-non-ru-domains.txt"
RU_ADS_ADD_SOURCE="${ROOT_DIR}/ru-ads-add.txt"
RU_ADS_ALLOW_SOURCE="${ROOT_DIR}/ru-ads-allow.txt"

[[ -f "${RU_NON_RU_SOURCE}" ]] || {
  echo "❌ Не найден файл: ${RU_NON_RU_SOURCE}" >&2
  exit 1
}

# optional override files
[[ -f "${RU_ADS_ADD_SOURCE}" ]] || : > "${RU_ADS_ADD_SOURCE}"
[[ -f "${RU_ADS_ALLOW_SOURCE}" ]] || : > "${RU_ADS_ALLOW_SOURCE}"

mkdir -p "${RELEASE_DIR}"

# URLs
ANTIFILTER_DOMAINS_URL="https://community.antifilter.download/list/domains.lst"
ANTIFILTER_COMMUNITY_IP_URL="https://community.antifilter.download/list/community.lst"
ALLYOUNEED_IP_URL="https://antifilter.download/list/allyouneed.lst"
ADS_REJECT_URL="https://raw.githubusercontent.com/Loyalsoldier/surge-rules/release/ruleset/reject.txt"
RU_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/ru.txt"
PRIVATE_IP_URL="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/private.txt"

DOMAIN_LIST_COMMUNITY_REPO="https://github.com/v2fly/domain-list-community.git"
DOMAIN_LIST_CUSTOM_REPO="https://github.com/runetfreedom/domain-list-custom.git"

log "Загрузка списков..."

fetch "${ANTIFILTER_DOMAINS_URL}" "${TEMP_DIR}/domains.lst"
fetch "${ANTIFILTER_COMMUNITY_IP_URL}" "${TEMP_DIR}/community-ip.lst"
fetch "${ALLYOUNEED_IP_URL}" "${TEMP_DIR}/allyouneed-ip.lst"
fetch "${ADS_REJECT_URL}" "${TEMP_DIR}/reject.txt"
fetch "${RU_IP_URL}" "${TEMP_DIR}/ru.txt"
fetch "${PRIVATE_IP_URL}" "${TEMP_DIR}/private.txt"

cp "${RU_NON_RU_SOURCE}" "${TEMP_DIR}/ru-non-ru-domains.txt"
cp "${RU_ADS_ADD_SOURCE}" "${TEMP_DIR}/ru-ads-add.txt"
cp "${RU_ADS_ALLOW_SOURCE}" "${TEMP_DIR}/ru-ads-allow.txt"

log "Подготовка geosite source для category-ru/category-gov-ru..."

git clone --depth=1 "${DOMAIN_LIST_COMMUNITY_REPO}" "${TEMP_DIR}/domain-list-community"
git clone --depth=1 "${DOMAIN_LIST_CUSTOM_REPO}" "${TEMP_DIR}/domain-list-custom"

mkdir -p "${TEMP_DIR}/domain-export"
(
  cd "${TEMP_DIR}/domain-list-custom"
  go mod download
  go run ./ \
    --exportlists=category-ru,category-gov-ru \
    --datapath="${TEMP_DIR}/domain-list-community/data" \
    --outputpath="${TEMP_DIR}/domain-export"
)

log "Конвертация..."

python3 - "${TEMP_DIR}" "${RELEASE_DIR}" <<'PY'
import json
import sys
from pathlib import Path
from collections import defaultdict

temp = Path(sys.argv[1])
release = Path(sys.argv[2])

BLANKET_DIRECT_SUFFIXES = {"ru", "su", "xn--p1ai"}

def empty_rules():
    return {
        "domain": set(),
        "full": set(),
        "keyword": set(),
        "regexp": set(),
    }

def merge_rules(*rule_sets):
    out = empty_rules()
    for rs in rule_sets:
        for key in out:
            out[key].update(rs.get(key, set()))
    return out

def read_lines(path: Path):
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()

def clean_host(host: str):
    host = host.strip().lower().lstrip("\ufeff").rstrip(".")
    if host.startswith("*."):
        host = host[2:]
    return host or None

def parse_mixed_domain_source(path: Path):
    """
    Поддерживает:
      - plain domain -> domain:
      - full:host
      - domain:host
      - keyword:foo
      - regexp:...
      - DOMAIN-SUFFIX,host
      - DOMAIN,host
      - DOMAIN-KEYWORD,foo
    """
    out = empty_rules()

    for raw in read_lines(path):
        line = raw.strip().lstrip("\ufeff")
        if not line or line.startswith("#"):
            continue

        # простой inline-comment для локальных txt
        if "#" in line and not line.startswith("regexp:"):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue

        upper = line.upper()

        if upper.startswith("DOMAIN-SUFFIX,"):
            host = clean_host(line.split(",", 1)[1])
            if host:
                out["domain"].add(host)
            continue

        if upper.startswith("DOMAIN,"):
            host = clean_host(line.split(",", 1)[1])
            if host:
                out["full"].add(host)
            continue

        if upper.startswith("DOMAIN-KEYWORD,"):
            value = line.split(",", 1)[1].strip().lower()
            if value:
                out["keyword"].add(value)
            continue

        if line.startswith("domain:"):
            host = clean_host(line[7:])
            if host:
                out["domain"].add(host)
            continue

        if line.startswith("full:"):
            host = clean_host(line[5:])
            if host:
                out["full"].add(host)
            continue

        if line.startswith("keyword:"):
            value = line[8:].strip().lower()
            if value:
                out["keyword"].add(value)
            continue

        if line.startswith("regexp:"):
            value = line[7:].strip()
            if value:
                out["regexp"].add(value)
            continue

        host = clean_host(line)
        if host:
            out["domain"].add(host)

    return out

def parse_plain_ip_list(path: Path):
    out = set()
    for raw in read_lines(path):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        out.add(line)
    return sorted(out)

def suffixes(host: str):
    parts = host.split(".")
    for i in range(len(parts)):
        yield ".".join(parts[i:])

def is_under(host: str, suffix: str) -> bool:
    return host == suffix or host.endswith("." + suffix)

def is_direct_host(host: str, direct_domains: set, direct_fulls: set) -> bool:
    if host in direct_fulls:
        return True
    for s in suffixes(host):
        if s in BLANKET_DIRECT_SUFFIXES or s in direct_domains:
            return True
    return False

def build_descendant_maps(direct_domains: set, direct_fulls: set):
    domain_desc = defaultdict(set)
    full_desc = defaultdict(set)

    for d in direct_domains:
        for s in suffixes(d):
            domain_desc[s].add(d)

    for f in direct_fulls:
        for s in suffixes(f):
            full_desc[s].add(f)

    return domain_desc, full_desc

def compress_domains(domains: set):
    kept = set()
    for d in sorted(domains, key=lambda x: (x.count("."), x)):
        redundant = False
        parts = d.split(".")
        for i in range(1, len(parts)):
            parent = ".".join(parts[i:])
            if parent in kept:
                redundant = True
                break
        if not redundant:
            kept.add(d)
    return kept

def remove_fulls_covered_by_domains(fulls: set, domains: set):
    result = set()
    for f in fulls:
        covered = False
        for s in suffixes(f):
            if s in domains:
                covered = True
                break
        if not covered:
            result.add(f)
    return result

def apply_allowlist(domains: set, fulls: set, allow_domains: set, allow_fulls: set):
    new_domains = {d for d in domains if not any(is_under(d, a) for a in allow_domains)}
    new_fulls = {f for f in fulls if not any(is_under(f, a) for a in allow_domains)}
    new_fulls -= allow_fulls
    return new_domains, new_fulls

def write_text(path: Path, lines):
    content = "\n".join(lines)
    if content:
        content += "\n"
    path.write_text(content, encoding="utf-8")

def render_canonical(path: Path, domains: set, fulls: set):
    lines = [f"domain:{d}" for d in sorted(domains)]
    lines += [f"full:{f}" for f in sorted(fulls)]
    write_text(path, lines)

def render_local_plain(path: Path, domains: set, fulls: set):
    lines = sorted(domains)
    lines += [f"full:{f}" for f in sorted(fulls)]
    write_text(path, lines)

def render_surge(path: Path, domains: set, fulls: set, keywords: set = None):
    keywords = keywords or set()
    lines = [f"DOMAIN-SUFFIX,{d}" for d in sorted(domains)]
    lines += [f"DOMAIN,{f}" for f in sorted(fulls)]
    lines += [f"DOMAIN-KEYWORD,{k}" for k in sorted(keywords)]
    write_text(path, lines)

def render_clash_yaml_domains(path: Path, domains: set, fulls: set, keywords: set = None):
    keywords = keywords or set()
    lines = ["payload:"]
    lines += [f"  - DOMAIN-SUFFIX,{d}" for d in sorted(domains)]
    lines += [f"  - DOMAIN,{f}" for f in sorted(fulls)]
    lines += [f"  - DOMAIN-KEYWORD,{k}" for k in sorted(keywords)]
    write_text(path, lines)

def render_clash_yaml_ips(path: Path, ips):
    lines = ["payload:"]
    lines += [f"  - {ip}" for ip in ips]
    write_text(path, lines)

def render_singbox_domains(path: Path, domains: set, fulls: set, keywords: set = None):
    keywords = keywords or set()
    rules = []
    for d in sorted(domains):
        rules.append({"domain_suffix": d})
    for f in sorted(fulls):
        rules.append({"domain": f})
    for k in sorted(keywords):
        rules.append({"domain_keyword": k})

    path.write_text(
        json.dumps({"version": 1, "rules": rules}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )

def render_singbox_ips(path: Path, ips):
    rules = [{"ip_cidr": ip} for ip in ips]
    path.write_text(
        json.dumps({"version": 1, "rules": rules}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )

def render_adguard_home(path: Path, domains: set, fulls: set):
    hosts = sorted(set(domains) | set(fulls))
    lines = [f"||{h}^" for h in hosts]
    write_text(path, lines)

def render_pihole(path: Path, domains: set, fulls: set):
    hosts = sorted(set(domains) | set(fulls))
    write_text(path, hosts)

def render_hosts(path: Path, domains: set, fulls: set):
    hosts = sorted(set(domains) | set(fulls))
    lines = []
    for h in hosts:
        lines.append(f"0.0.0.0 {h}")
        lines.append(f"::1 {h}")
    write_text(path, lines)

def render_dnsmasq_forward(path: Path, domains: set):
    lines = [f"server=/{d}/127.0.0.1#5353" for d in sorted(domains)]
    write_text(path, lines)

def render_dnsmasq_block(path: Path, domains: set, fulls: set):
    hosts = sorted(set(domains) | set(fulls))
    lines = []
    for h in hosts:
        lines.append(f"address=/{h}/0.0.0.0")
        lines.append(f"address=/{h}/::")
    write_text(path, lines)

def fail_on_regexp(rule_set: dict, source_name: str):
    if not rule_set["regexp"]:
        return
    examples = ", ".join(sorted(rule_set["regexp"])[:5])
    total = len(rule_set["regexp"])
    raise SystemExit(
        f"❌ regexp rules found in {source_name}; export is not implemented for regexp. "
        f"count={total}; examples={examples}"
    )

# ===== Parse sources =====

antifilter_domains = sorted(parse_plain_ip_list(temp / "domains.lst"))
antifilter_ips = sorted(set(parse_plain_ip_list(temp / "community-ip.lst")) | set(parse_plain_ip_list(temp / "allyouneed-ip.lst")))
ru_ips = parse_plain_ip_list(temp / "ru.txt")
private_ips = parse_plain_ip_list(temp / "private.txt")

global_ads = parse_mixed_domain_source(temp / "reject.txt")

category_ru = parse_mixed_domain_source(temp / "domain-export" / "category-ru.txt")
category_gov_ru = parse_mixed_domain_source(temp / "domain-export" / "category-gov-ru.txt")
ru_non_ru = parse_mixed_domain_source(temp / "ru-non-ru-domains.txt")

ru_ads_add = parse_mixed_domain_source(temp / "ru-ads-add.txt")
ru_ads_allow = parse_mixed_domain_source(temp / "ru-ads-allow.txt")

# ===== Fail-fast checks =====

fail_on_regexp(category_ru, "category-ru.txt")
fail_on_regexp(category_gov_ru, "category-gov-ru.txt")

# ===== Existing outputs =====

# Mihomo / Surge-like
write_text(release / "mihomo-antifilter-domains.txt", [f"DOMAIN-SUFFIX,{d}" for d in antifilter_domains])
write_text(release / "mihomo-antifilter-ip.txt", [f"IP-CIDR,{ip}" for ip in antifilter_ips])
render_surge(release / "mihomo-adguard-domains.txt", global_ads["domain"], global_ads["full"], global_ads["keyword"])
write_text(release / "mihomo-ru-ip.txt", [f"IP-CIDR,{ip}" for ip in ru_ips])
write_text(release / "mihomo-private-ip.txt", [f"IP-CIDR,{ip}" for ip in private_ips])

# Shadowrocket
write_text(release / "shadowrocket-antifilter-domains.txt", [f"DOMAIN-SUFFIX,{d}" for d in antifilter_domains])
write_text(release / "shadowrocket-antifilter-ip.txt", [f"IP-CIDR,{ip}" for ip in antifilter_ips])
render_surge(release / "shadowrocket-adguard-domains.txt", global_ads["domain"], global_ads["full"], global_ads["keyword"])
write_text(release / "shadowrocket-ru-ip.txt", [f"IP-CIDR,{ip}" for ip in ru_ips])
write_text(release / "shadowrocket-private-ip.txt", [f"IP-CIDR,{ip}" for ip in private_ips])
render_surge(release / "shadowrocket-category-ru-domains.txt", category_ru["domain"], category_ru["full"], category_ru["keyword"])
render_surge(release / "shadowrocket-category-gov-ru-domains.txt", category_gov_ru["domain"], category_gov_ru["full"], category_gov_ru["keyword"])
render_surge(release / "shadowrocket-ru-non-ru-domains.txt", ru_non_ru["domain"], ru_non_ru["full"])

# Sing-box
render_singbox_domains(release / "singbox-antifilter-domains.json", set(antifilter_domains), set())
render_singbox_ips(release / "singbox-antifilter-ip.json", antifilter_ips)
render_singbox_domains(release / "singbox-adguard-domains.json", global_ads["domain"], global_ads["full"], global_ads["keyword"])
render_singbox_ips(release / "singbox-ru-ip.json", ru_ips)
render_singbox_ips(release / "singbox-private-ip.json", private_ips)
render_singbox_domains(release / "singbox-ru-non-ru-domains.json", ru_non_ru["domain"], ru_non_ru["full"])

# Clash
render_clash_yaml_domains(release / "clash-antifilter-domains.yaml", set(antifilter_domains), set())
render_clash_yaml_ips(release / "clash-antifilter-ip.yaml", antifilter_ips)
render_clash_yaml_domains(release / "clash-adguard-domains.yaml", global_ads["domain"], global_ads["full"], global_ads["keyword"])
render_clash_yaml_ips(release / "clash-ru-ip.yaml", ru_ips)
render_clash_yaml_ips(release / "clash-private-ip.yaml", private_ips)
render_clash_yaml_domains(release / "clash-ru-non-ru-domains.yaml", ru_non_ru["domain"], ru_non_ru["full"])

# DNSMasq
render_dnsmasq_forward(release / "dnsmasq-antifilter-domains.conf", set(antifilter_domains))

# AdGuard Home
render_adguard_home(release / "adguard-home-adguard-domains.txt", global_ads["domain"], global_ads["full"])
render_adguard_home(release / "adguard-home-antifilter-domains.txt", set(antifilter_domains), set())
write_text(release / "adguard-home-antifilter-ip.txt", antifilter_ips)

# Pi-hole
render_pihole(release / "pihole-adguard-domains.txt", global_ads["domain"], global_ads["full"])
render_pihole(release / "pihole-antifilter-domains.txt", set(antifilter_domains), set())

# HOSTS
render_hosts(release / "hosts-adguard-hosts.txt", global_ads["domain"], global_ads["full"])
render_hosts(release / "hosts-antifilter-hosts.txt", set(antifilter_domains), set())

# Plain local source
render_local_plain(release / "plain-ru-non-ru-domains.txt", ru_non_ru["domain"], ru_non_ru["full"])

# ===== Canonical direct universe =====

direct_universe = merge_rules(category_ru, category_gov_ru, ru_non_ru)
direct_domains = set(direct_universe["domain"]) | set(BLANKET_DIRECT_SUFFIXES)
direct_fulls = set(direct_universe["full"])

direct_domains = compress_domains(direct_domains)
direct_fulls = remove_fulls_covered_by_domains(direct_fulls, direct_domains)

render_canonical(release / "canonical-client-direct-universe.txt", direct_domains, direct_fulls)

# ===== Canonical RU ads =====

domain_desc, full_desc = build_descendant_maps(direct_domains, direct_fulls)

ru_ads_domains = set()
ru_ads_fulls = set()

# 1) ad DOMAIN-SUFFIX/domain:
for ad_domain in global_ads["domain"]:
    if is_direct_host(ad_domain, direct_domains, direct_fulls):
        ru_ads_domains.add(ad_domain)
    else:
        # если ad parent-domain сам не direct, но direct содержит потомков этого suffix
        ru_ads_domains.update(domain_desc.get(ad_domain, set()))
        ru_ads_fulls.update(full_desc.get(ad_domain, set()))

# 2) ad DOMAIN/full:
for ad_full in global_ads["full"]:
    if is_direct_host(ad_full, direct_domains, direct_fulls):
        ru_ads_fulls.add(ad_full)

# 3) manual add
ru_ads_domains |= ru_ads_add["domain"]
ru_ads_fulls |= ru_ads_add["full"]

# 4) allowlist
ru_ads_domains, ru_ads_fulls = apply_allowlist(
    ru_ads_domains,
    ru_ads_fulls,
    ru_ads_allow["domain"],
    ru_ads_allow["full"],
)

# 5) compress / dedupe
ru_ads_domains = compress_domains(ru_ads_domains)
ru_ads_fulls = remove_fulls_covered_by_domains(ru_ads_fulls, ru_ads_domains)

render_canonical(release / "canonical-ru-ads.txt", ru_ads_domains, ru_ads_fulls)
render_pihole(release / "plain-ru-ads.txt", ru_ads_domains, ru_ads_fulls)

# ===== RU ads client formats =====

render_surge(release / "mihomo-ru-ads.txt", ru_ads_domains, ru_ads_fulls)
render_surge(release / "shadowrocket-ru-ads.txt", ru_ads_domains, ru_ads_fulls)
render_clash_yaml_domains(release / "clash-ru-ads.yaml", ru_ads_domains, ru_ads_fulls)
render_singbox_domains(release / "singbox-ru-ads.json", ru_ads_domains, ru_ads_fulls)
render_adguard_home(release / "adguard-home-ru-ads.txt", ru_ads_domains, ru_ads_fulls)
render_pihole(release / "pihole-ru-ads.txt", ru_ads_domains, ru_ads_fulls)
render_hosts(release / "hosts-ru-ads.txt", ru_ads_domains, ru_ads_fulls)
render_dnsmasq_block(release / "dnsmasq-ru-ads.conf", ru_ads_domains, ru_ads_fulls)

# ===== Diagnostics =====

diagnostic_lines = []

diagnostic_lines.append("# Ignored direct-universe keywords (not included into canonical direct universe matching)")
for v in sorted(direct_universe["keyword"]):
    diagnostic_lines.append(f"direct-keyword:{v}")

diagnostic_lines.append("")
diagnostic_lines.append("# Ignored direct-universe regexp")
for v in sorted(direct_universe["regexp"]):
    diagnostic_lines.append(f"direct-regexp:{v}")

diagnostic_lines.append("")
diagnostic_lines.append("# Ignored ad keywords for canonical ru-ads")
for v in sorted(global_ads["keyword"]):
    diagnostic_lines.append(f"ads-keyword:{v}")

diagnostic_lines.append("")
diagnostic_lines.append("# Manual add keywords/regexp (ignored in canonical v1)")
for v in sorted(ru_ads_add["keyword"]):
    diagnostic_lines.append(f"add-keyword:{v}")
for v in sorted(ru_ads_add["regexp"]):
    diagnostic_lines.append(f"add-regexp:{v}")

diagnostic_lines.append("")
diagnostic_lines.append("# Manual allow keywords/regexp (ignored in canonical v1)")
for v in sorted(ru_ads_allow["keyword"]):
    diagnostic_lines.append(f"allow-keyword:{v}")
for v in sorted(ru_ads_allow["regexp"]):
    diagnostic_lines.append(f"allow-regexp:{v}")

write_text(release / "diagnostic-ru-ads-unhandled.txt", diagnostic_lines)

# ===== Simple stats =====

stats = {
    "antifilter_domains": len(antifilter_domains),
    "antifilter_ips": len(antifilter_ips),
    "global_ads_domain_rules": len(global_ads["domain"]),
    "global_ads_full_rules": len(global_ads["full"]),
    "global_ads_keyword_rules": len(global_ads["keyword"]),
    "direct_universe_domains": len(direct_domains),
    "direct_universe_fulls": len(direct_fulls),
    "ru_ads_domains": len(ru_ads_domains),
    "ru_ads_fulls": len(ru_ads_fulls),
}

stats_lines = [f"{k}={v}" for k, v in stats.items()]
write_text(release / "stats.txt", stats_lines)
PY

log "✅ Готово"
log "Основные новые файлы:"
log "  release/canonical-client-direct-universe.txt"
log "  release/canonical-ru-ads.txt"
log "  release/diagnostic-ru-ads-unhandled.txt"
log "  release/shadowrocket-ru-ads.txt"
log "  release/clash-ru-ads.yaml"
log "  release/singbox-ru-ads.json"
