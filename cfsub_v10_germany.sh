#!/usr/bin/env bash
set -euo pipefail

# ===== 基础配置 =====
GITHUB_USER="${GITHUB_USER:-ywsqbw1234}"
GITHUB_REPO="${GITHUB_REPO:-vps-tools}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
WORKDIR="${WORKDIR:-/root/${GITHUB_REPO}}"

URL_FILE="${URL_FILE:-/etc/sing-box/url.txt}"
FIXED_IP_FILE="${FIXED_IP_FILE:-/root/cf_fixed_ip.txt}"

DOMAIN="${DOMAIN:-de.ywsqbw.uk}"
VPS_IP="${VPS_IP:-82.139.205.22}"

SBOX_CONFIG="${SBOX_CONFIG:-/etc/sing-box/config.json}"

HY2_SERVER="${HY2_SERVER:-$VPS_IP}"
HY2_SNI="${HY2_SNI:-www.bing.com}"
HY2_INSECURE="${HY2_INSECURE:-true}"

HY2_MAIN_PORT="${HY2_MAIN_PORT:-38049}"
HY2_LIMIT5_PORT="${HY2_LIMIT5_PORT:-38050}"
HY2_LIMIT10_PORT="${HY2_LIMIT10_PORT:-38051}"

CANDIDATES="${CANDIDATES:-250}"
KEEP_TOP="${KEEP_TOP:-12}"

SECRET_FILE="${SECRET_FILE:-/root/.cfsub_secret_dir}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# ====================

log() {
  echo "[cfsub] $*" >&2
}

die() {
  echo "[cfsub][ERR] $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

b64dec() {
  local s="$1"
  local mod=$(( ${#s} % 4 ))
  if [[ "$mod" -eq 2 ]]; then
    s="${s}=="
  elif [[ "$mod" -eq 3 ]]; then
    s="${s}="
  fi
  echo "$s" | base64 -d 2>/dev/null
}

b64enc_oneline() {
  base64 -w0
}

ensure_secret_dir() {
  if [[ -f "$SECRET_FILE" ]]; then
    cat "$SECRET_FILE"
    return
  fi
  local s
  s="$(openssl rand -hex 18)"
  echo "$s" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  echo "$s"
}

ensure_repo() {
  if [[ -d "$WORKDIR/.git" ]]; then
    return
  fi
  git clone "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "$WORKDIR" >/dev/null
}

pick_vmess_template() {
  [[ -f "$URL_FILE" ]] || die "找不到 $URL_FILE"

  mapfile -t urls < <(grep -E '^vmess://' "$URL_FILE" 2>/dev/null || true)
  [[ "${#urls[@]}" -gt 0 ]] || die "$URL_FILE 里没有 vmess://"

  local -a valid=()
  local -a names=()

  for u in "${urls[@]}"; do
    local j
    j="$(b64dec "${u#vmess://}" || true)"
    if [[ -n "$j" ]] && echo "$j" | jq -e '.ps and .id' >/dev/null 2>&1; then
      valid+=("$u")
      names+=("$(echo "$j" | jq -r .ps)")
    fi
  done

  [[ "${#valid[@]}" -gt 0 ]] || die "没有可用 vmess 模板"

  if [[ "${#valid[@]}" -eq 1 ]]; then
    echo "${valid[0]}"
    return
  fi

  echo "检测到多个模板，请选择："
  local i
  for i in "${!names[@]}"; do
    printf " %2d) %s\n" "$((i+1))" "${names[$i]}"
  done

  while true; do
    read -r -p "输入编号 (1-${#valid[@]}): " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le "${#valid[@]}" ]]; then
      echo "${valid[$((n-1))]}"
      return
    fi
  done
}

declare -A FIXED_SET
declare -A FIXNAME

read_fixed_nodes() {
  local fixed_nodes_txt="$1"
  : > "$fixed_nodes_txt"
  FIXED_SET=()
  FIXNAME=()

  [[ -f "$FIXED_IP_FILE" ]] || return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    local target name
    target="$(echo "$line" | awk '{print $NF}')"
    name="$(echo "$line" | awk '{NF--; sub(/[ \t]+$/,""); print}')"

    if [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$target" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      echo "$target" >> "$fixed_nodes_txt"
      FIXED_SET["$target"]=1
      FIXNAME["$target"]="$name"
    fi
  done < "$FIXED_IP_FILE"
}

is_fixed_node() {
  local node="$1"
  [[ -n "${FIXED_SET[$node]:-}" ]]
}

fetch_ips_sources() {
  local tmp="$1"
  : > "$tmp"

  curl -fsSL "https://www.wetest.vip/page/cloudflare/address_v4.html" \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' >> "$tmp" || true

  curl -fsSL "https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/ip.txt" \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' >> "$tmp" || true

  curl -fsSL "https://api.uouin.com/cloudflare.html" \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' >> "$tmp" || true

  awk '
    function ok(ip, a, i) {
      split(ip, a, ".")
      if (length(a) != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (a[i] !~ /^[0-9]+$/ || a[i] < 0 || a[i] > 255) return 0
      }
      return 1
    }
    { gsub(/\r/, ""); if (ok($0)) print $0 }
  ' "$tmp" | sort -u
}

speedtest_pick_top() {
  local candidates_file="$1"
  local out_file="$2"

  local tmpdir ip_in result_csv
  tmpdir="$(mktemp -d)"
  ip_in="${tmpdir}/ip_in.txt"
  result_csv="${tmpdir}/result.csv"

  head -n "$CANDIDATES" "$candidates_file" > "$ip_in"
  [[ -s "$ip_in" ]] || die "没有候选 IP 可测速"

  log "测速候选：$(wc -l < "$ip_in" | tr -d ' ') 条 → 取最快 ${KEEP_TOP} 条"
  cfst -f "$ip_in" -o "$result_csv" -dd -t 4 -n 200 >/dev/null 2>&1 || true
  [[ -s "$result_csv" ]] || die "cfst 未输出结果"

  awk -F',' 'NR==1{next} $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' "$result_csv" \
    | head -n "$KEEP_TOP" > "$out_file"

  rm -rf "$tmpdir"
}

write_builtin_tw_nodes() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
  - { name: "[anytls]🇹🇼台湾T01 家宽 1x 直连", type: anytls, server: tw-hinet-1.nchc.cc, port: 27171, password: d14015da-1861-4439-9ca5-da877f917f86, udp: true, sni: tw-hinet-1.nchc.cc, skip-cert-verify: true }
  - { name: "[anytls]🇹🇼台湾T02 家宽 1x 直连", type: anytls, server: tw-hinet-2.nchc.cc, port: 27172, password: d14015da-1861-4439-9ca5-da877f917f86, udp: true, sni: tw-hinet-2.nchc.cc, skip-cert-verify: true }
EOF
}

write_builtin_tw_names() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
[anytls]🇹🇼台湾T01 家宽 1x 直连
[anytls]🇹🇼台湾T02 家宽 1x 直连
EOF
}
write_builtin_hk_nodes() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
  - { name: "[anytls]🇭🇰香港T02 IDC 1x 直连", type: anytls, server: hk-aws-1.nchc.cc, port: 27152, password: d14015da-1861-4439-9ca5-da877f917f86, udp: true, sni: hk-aws-1.nchc.cc, skip-cert-verify: true}
  - { name: "[anytls]🇭🇰香港T03 IDC 1x 直连", type: anytls, server: hk-aws-2.nchc.cc, port: 27153, password: d14015da-1861-4439-9ca5-da877f917f86, udp: true, sni: hk-aws-2.nchc.cc, skip-cert-verify: true}
EOF
}

write_builtin_hk_names() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
[anytls]🇭🇰香港T02 IDC 1x 直连
[anytls]🇭🇰香港T03 IDC 1x 直连
EOF
}
write_builtin_de_nodes() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
  - { name: "[anytls]🇩🇪德国 T01 家宽 1x 直连", type: anytls, server: de-lisa-1.nchc.cc, port: 27181, password: "d14015da-1861-4439-9ca5-da877f917f86", udp: true, sni: de-lisa-1.nchc.cc, skip-cert-verify: true }
EOF
}

write_builtin_de_names() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
[anytls]🇩🇪德国 T01 家宽 1x 直连
EOF
}

write_builtin_jp_nodes() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
  - { name: "[anytls]🇯🇵日本T01 IDC 1x 直连", type: anytls, server: jp-aws-1.nchc.cc, port: 27161, password: "d14015da-1861-4439-9ca5-da877f917f86", udp: true, sni: jp-aws-1.nchc.cc, skip-cert-verify: true }
EOF
}

write_builtin_jp_names() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
[anytls]🇯🇵日本T01 IDC 1x 直连
EOF
}

urlenc() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

read_hy2_info() {
  [[ -f "$SBOX_CONFIG" ]] || die "找不到 $SBOX_CONFIG"

  HY2_PASSWORD="$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$SBOX_CONFIG" | head -n1)"
  [[ -n "$HY2_PASSWORD" ]] || die "无法从 $SBOX_CONFIG 读取 Hysteria2 密码"
}

write_builtin_hy2_proxies() {
  local out_file="$1"

  {
    echo '  - name: "DE-HY2-直连"'
    echo '    type: hysteria2'
    echo "    server: ${HY2_SERVER}"
    echo "    port: ${HY2_MAIN_PORT}"
    echo "    password: \"${HY2_PASSWORD}\""
    [[ -n "$HY2_SNI" ]] && echo "    sni: \"${HY2_SNI}\""
    echo "    skip-cert-verify: ${HY2_INSECURE}"
    echo "    alpn:"
    echo "      - h3"
    echo
    echo '  - name: "DE-HY2-50M"'
    echo '    type: hysteria2'
    echo "    server: ${HY2_SERVER}"
    echo "    port: ${HY2_LIMIT5_PORT}"
    echo "    password: \"${HY2_PASSWORD}\""
    echo '    up: "50 Mbps"'
    echo '    down: "50 Mbps"'
    [[ -n "$HY2_SNI" ]] && echo "    sni: \"${HY2_SNI}\""
    echo "    skip-cert-verify: ${HY2_INSECURE}"
    echo "    alpn:"
    echo "      - h3"
    echo
    echo '  - name: "DE-HY2-100M"'
    echo '    type: hysteria2'
    echo "    server: ${HY2_SERVER}"
    echo "    port: ${HY2_LIMIT10_PORT}"
    echo "    password: \"${HY2_PASSWORD}\""
    echo '    up: "100 Mbps"'
    echo '    down: "100 Mbps"'
    [[ -n "$HY2_SNI" ]] && echo "    sni: \"${HY2_SNI}\""
    echo "    skip-cert-verify: ${HY2_INSECURE}"
    echo "    alpn:"
    echo "      - h3"
  } > "$out_file"
}

write_builtin_hy2_names() {
  local out_file="$1"
  cat > "$out_file" <<'EOF'
DE-HY2-直连
DE-HY2-50M
DE-HY2-100M
EOF
}

write_builtin_hy2_links() {
  local out_file="$1"
  local enc_pw query
  enc_pw="$(urlenc "$HY2_PASSWORD")"
  query="insecure=1"
  if [[ -n "$HY2_SNI" ]]; then
    query="${query}&sni=$(urlenc "$HY2_SNI")"
  fi

  cat > "$out_file" <<EOF
hysteria2://${enc_pw}@${HY2_SERVER}:${HY2_MAIN_PORT}/?${query}#DE-HY2-直连
hysteria2://${enc_pw}@${HY2_SERVER}:${HY2_LIMIT5_PORT}/?${query}#DE-HY2-50M
hysteria2://${enc_pw}@${HY2_SERVER}:${HY2_LIMIT10_PORT}/?${query}#DE-HY2-100M
EOF
}

push_github_files() {
  local secret_dir="$1"
  local sub_b64="$2"
  local clash_yaml="$3"

  [[ -n "$GITHUB_TOKEN" ]] || die "请先 export GITHUB_TOKEN=你的token"

  ensure_repo
  cd "$WORKDIR"

  mkdir -p "$secret_dir"
  echo -n "$sub_b64" > "${secret_dir}/sub.txt"
  cp -f "$clash_yaml" "${secret_dir}/clash.yaml"

  git add "${secret_dir}/sub.txt" "${secret_dir}/clash.yaml" >/dev/null 2>&1 || true

  if git diff --cached --quiet; then
    log "内容没有变化，不提交。"
    return
  fi

  git commit -m "update nodes $(date -Is)" >/dev/null || true

  local askpass
  askpass="$(mktemp)"
  chmod 700 "$askpass"
  cat > "$askpass" <<'EOF'
#!/usr/bin/env bash
echo "$GITHUB_TOKEN"
EOF

  GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git pull --rebase "https://${GITHUB_USER}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${GITHUB_BRANCH}" >/dev/null 2>&1 || true

  GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git push "https://${GITHUB_USER}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${GITHUB_BRANCH}" >/dev/null

  rm -f "$askpass"
  log "已 push 到 GitHub ✅"
}

main() {
  need_cmd jq
  need_cmd curl
  need_cmd git
  need_cmd cfst
  need_cmd python3
  need_cmd openssl
  need_cmd base64

  local tpl vmjson
  tpl="$(pick_vmess_template)"
  vmjson="$(b64dec "${tpl#vmess://}")"

  local ps uuid port raw_path aid fp
  ps="DE"
  uuid="$(echo "$vmjson" | jq -r .id)"
  port="$(echo "$vmjson" | jq -r '.port // 443')"
  raw_path="$(echo "$vmjson" | jq -r '.path // "/"')"
  aid="$(echo "$vmjson" | jq -r '.aid // "0"')"
  fp="$(echo "$vmjson" | jq -r '.fp // "firefox"')"

  [[ -n "$uuid" && "$uuid" != "null" ]] || die "模板里没有 UUID(id)"

  local ws_path early_data
  ws_path="${raw_path%%\?ed=*}"
  if [[ "$raw_path" =~ \?ed=([0-9]+) ]]; then
    early_data="${BASH_REMATCH[1]}"
  else
    early_data="0"
  fi
  [[ -n "$ws_path" ]] || ws_path="/"

  local tmpdir
  local fixed_nodes_txt all_ips auto_top final_nodes vmess_list clash_yaml
  local airport_tw_proxies airport_tw_names
  local airport_de_proxies airport_de_names
  local airport_jp_proxies airport_jp_names
  local airport_hk_proxies airport_hk_names
  local hy2_proxies hy2_names hy2_links

  tmpdir="$(mktemp -d)"
  fixed_nodes_txt="${tmpdir}/fixed_nodes.txt"
  all_ips="${tmpdir}/all_ips.txt"
  auto_top="${tmpdir}/auto_top.txt"
  final_nodes="${tmpdir}/final_nodes.txt"
  vmess_list="${tmpdir}/vmess.txt"
  clash_yaml="${tmpdir}/clash.yaml"
  airport_tw_proxies="${tmpdir}/airport_tw_proxies.txt"
  airport_tw_names="${tmpdir}/airport_tw_names.txt"
  airport_de_proxies="${tmpdir}/airport_de_proxies.txt"
  airport_de_names="${tmpdir}/airport_de_names.txt"
  airport_jp_proxies="${tmpdir}/airport_jp_proxies.txt"
  airport_jp_names="${tmpdir}/airport_jp_names.txt"
  airport_hk_proxies="${tmpdir}/airport_hk_proxies.txt"
  airport_hk_names="${tmpdir}/airport_hk_names.txt"
  hy2_proxies="${tmpdir}/hy2_proxies.txt"
  hy2_names="${tmpdir}/hy2_names.txt"
  hy2_links="${tmpdir}/hy2_links.txt"

  read_fixed_nodes "$fixed_nodes_txt"
  log "固定节点数量：$(wc -l < "$fixed_nodes_txt" 2>/dev/null | tr -d ' ' || echo 0)"

  write_builtin_tw_nodes "$airport_tw_proxies"
  write_builtin_tw_names "$airport_tw_names"
  write_builtin_de_nodes "$airport_de_proxies"
  write_builtin_de_names "$airport_de_names"
  write_builtin_jp_nodes "$airport_jp_proxies"
  write_builtin_jp_names "$airport_jp_names"
  write_builtin_hk_nodes "$airport_hk_proxies"
  write_builtin_hk_names "$airport_hk_names"
  read_hy2_info
  write_builtin_hy2_proxies "$hy2_proxies"
  write_builtin_hy2_names "$hy2_names"
  write_builtin_hy2_links "$hy2_links"

  log "内置台湾节点数量：$(wc -l < "$airport_tw_names" | tr -d ' ')"
  log "内置 Hy2 节点数量：$(wc -l < "$hy2_names" | tr -d ' ')"

  fetch_ips_sources "$all_ips" > "${all_ips}.sorted"
  mv "${all_ips}.sorted" "$all_ips"
  log "候选 IP 总数：$(wc -l < "$all_ips" | tr -d ' ')"

  speedtest_pick_top "$all_ips" "$auto_top"
  log "自动最快 IP 数量：$(wc -l < "$auto_top" | tr -d ' ')"

  : > "$final_nodes"
  if [[ -s "$fixed_nodes_txt" ]]; then
    cat "$fixed_nodes_txt" >> "$final_nodes"
  fi

  if [[ -s "$fixed_nodes_txt" ]]; then
    grep -vxFf <(grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$fixed_nodes_txt" || true) "$auto_top" >> "$final_nodes" || true
  else
    cat "$auto_top" >> "$final_nodes"
  fi

  awk '!seen[$0]++' "$final_nodes" > "${final_nodes}.u" && mv "${final_nodes}.u" "$final_nodes"
  log "最终用于生成 VPS 节点数量：$(wc -l < "$final_nodes" | tr -d ' ')"

  : > "$vmess_list"
  local fix_i=0 cf_i=0
  while IFS= read -r node; do
    local newps tag display mod b64
    if is_fixed_node "$node"; then
      fix_i=$((fix_i+1))
      tag="$(printf "%02d" "$fix_i")"
      display="${FIXNAME[$node]:-}"
      if [[ -n "$display" ]]; then
        newps="${ps}-FIX${tag}-${display}"
      else
        newps="${ps}-FIX${tag}"
      fi
    else
      cf_i=$((cf_i+1))
      tag="$(printf "%02d" "$cf_i")"
      newps="${ps}-CF${tag}"
    fi

    mod="$(echo "$vmjson" | jq \
      --arg add "$node" \
      --arg host "$DOMAIN" \
      --arg sni "$DOMAIN" \
      --arg ps "$newps" \
      '.add=$add | .host=$host | .sni=$sni | .ps=$ps')"

    b64="$(echo -n "$mod" | base64 -w0)"
    echo "vmess://${b64}" >> "$vmess_list"
  done < "$final_nodes"

  local sub_b64
  sub_b64="$(
    {
      cat "$vmess_list"
      cat "$hy2_links"
    } | awk 'NF' | base64 -w0
  )"

  {
    echo "mixed-port: 7890"
    echo "allow-lan: true"
    echo "bind-address: '*'"
    echo "mode: rule"
    echo "log-level: info"
    echo "external-controller: '127.0.0.1:9090'"
    echo "ipv6: true"
    echo ""
    echo "dns:"
    echo "  enable: true"
    echo "  ipv6: true"
    echo "  enhanced-mode: fake-ip"
    echo "  fake-ip-range: 198.18.0.1/16"
    echo "  default-nameserver:"
    echo "    - 1.1.1.1"
    echo "    - 8.8.8.8"
    echo "  nameserver:"
    echo "    - 1.1.1.1"
    echo "    - 8.8.8.8"
    echo "  fallback:"
    echo "    - 1.1.1.1"
    echo "    - 8.8.8.8"
    echo ""
    echo "proxies:"

    fix_i=0
    cf_i=0
    while IFS= read -r node; do
      local name tag display
      if is_fixed_node "$node"; then
        fix_i=$((fix_i+1))
        tag="$(printf "%02d" "$fix_i")"
        display="${FIXNAME[$node]:-}"
        if [[ -n "$display" ]]; then
          name="${ps}-FIX${tag}-${display}"
        else
          name="${ps}-FIX${tag}"
        fi
      else
        cf_i=$((cf_i+1))
        tag="$(printf "%02d" "$cf_i")"
        name="${ps}-CF${tag}"
      fi

      echo "  - name: \"${name}\""
      echo "    type: vmess"
      echo "    server: ${node}"
      echo "    port: ${port}"
      echo "    uuid: ${uuid}"
      echo "    alterId: ${aid}"
      echo "    cipher: auto"
      echo "    udp: true"
      echo "    tls: true"
      echo "    servername: ${DOMAIN}"
      echo "    client-fingerprint: ${fp}"
      echo "    network: ws"
      echo "    ws-opts:"
      echo "      path: \"${ws_path}\""
      echo "      headers:"
      echo "        Host: ${DOMAIN}"
      if [[ "$early_data" != "0" ]]; then
        echo "      max-early-data: ${early_data}"
        echo "      early-data-header-name: Sec-WebSocket-Protocol"
      fi
    done < "$final_nodes"

    while IFS= read -r line; do
       echo "${line}"
    done < "$airport_tw_proxies"

    while IFS= read -r line; do
       echo "${line}"
    done < "$airport_de_proxies"

    while IFS= read -r line; do
       echo "${line}"
    done < "$airport_jp_proxies"

    while IFS= read -r line; do
       echo "${line}"
    done < "$airport_hk_proxies"

    while IFS= read -r line; do
       echo "${line}"
    done < "$hy2_proxies"

    echo ""
    echo "proxy-groups:"
    echo "  - name: \"节点选择\""
    echo "    type: select"
    echo "    proxies:"

    fix_i=0
    cf_i=0
    while IFS= read -r node; do
      local name tag display
      if is_fixed_node "$node"; then
        fix_i=$((fix_i+1))
        tag="$(printf "%02d" "$fix_i")"
        display="${FIXNAME[$node]:-}"
        if [[ -n "$display" ]]; then
          name="${ps}-FIX${tag}-${display}"
        else
          name="${ps}-FIX${tag}"
        fi
      else
        cf_i=$((cf_i+1))
        tag="$(printf "%02d" "$cf_i")"
        name="${ps}-CF${tag}"
      fi
      echo "      - \"${name}\""
    done < "$final_nodes"
    while IFS= read -r n; do
      [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$hy2_names"
    while IFS= read -r n; do
     [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$airport_tw_names"
    while IFS= read -r n; do
     [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$airport_hk_names"
    while IFS= read -r n; do
     [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$airport_jp_names"
    while IFS= read -r n; do
     [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$airport_de_names"
    echo "      - DIRECT"

    echo "  - name: \"自动选择\""
    echo "    type: select"
    echo "    proxies:"
    fix_i=0
    cf_i=0
    while IFS= read -r node; do
      local name tag display
      if is_fixed_node "$node"; then
        fix_i=$((fix_i+1))
        tag="$(printf "%02d" "$fix_i")"
        display="${FIXNAME[$node]:-}"
        if [[ -n "$display" ]]; then
          name="${ps}-FIX${tag}-${display}"
        else
          name="${ps}-FIX${tag}"
        fi
      else
        cf_i=$((cf_i+1))
        tag="$(printf "%02d" "$cf_i")"
        name="${ps}-CF${tag}"
      fi
      echo "      - \"${name}\""
    done < "$final_nodes"
    echo "      - DIRECT"

    echo "  - name: \"X专用\""
    echo "    type: select"
    echo "    proxies:"
    echo "      - \"节点选择\""
    echo "      - \"自动选择\""
    while IFS= read -r n; do
     [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$airport_tw_names"
    echo "      - DIRECT"

    echo "  - name: \"ChatGPT\""
    echo "    type: select"
    echo "    proxies:"
    echo "      - \"节点选择\""
    echo "      - \"自动选择\""
    while IFS= read -r n; do
     [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$airport_de_names"
    echo "      - \"DE-HY2-直连\""
    echo "      - DIRECT"

    echo "  - name: \"T专用\""
    echo "    type: select"
    echo "    proxies:"
    echo "      - \"节点选择\""
    echo "      - \"自动选择\""
    while IFS= read -r n; do
     [[ -n "$n" ]] && echo "      - \"${n}\""
    done < "$airport_jp_names"
    echo "      - \"DE-HY2-直连\""
    echo "      - \"DE-HY2-100M\""
    echo "      - \"DE-HY2-50M\""
    echo "      - DIRECT"
    
    echo "  - name: \"流媒体\""
    echo "    type: select"
    echo "    proxies:"
    echo "      - \"节点选择\""
    echo "      - \"自动选择\""
    echo "      - \"DE-HY2-直连\""
    echo "      - \"DE-HY2-100M\""
    echo "      - \"DE-HY2-50M\""
    echo "      - DIRECT"

    echo "  - name: \"国内服务\""
    echo "    type: select"
    echo "    proxies:"
    echo "      - DIRECT"
    echo "      - \"节点选择\""

    echo "  - name: \"漏网之鱼\""
    echo "    type: select"
    echo "    proxies:"
    echo "      - \"节点选择\""
    echo "      - \"自动选择\""
    echo "      - DIRECT"

    echo ""
    echo "rules:"
    echo "  - PROCESS-NAME,Xshell.exe,DIRECT"
    echo "  - PROCESS-NAME,ssh.exe,DIRECT"
    echo "  - PROCESS-NAME,ssh,DIRECT"
    echo "  - PROCESS-NAME,Terminal,DIRECT"
    echo "  - PROCESS-NAME,WindowsTerminal.exe,DIRECT"
    echo "  - IP-CIDR,${VPS_IP}/32,DIRECT,no-resolve"
    echo "  - DOMAIN-SUFFIX,ywsqbw.uk,DIRECT"
    echo "  - DOMAIN,${DOMAIN},DIRECT"
    echo "  - DST-PORT,22,DIRECT"

    echo "  - DOMAIN-SUFFIX,x.com,X专用"
    echo "  - DOMAIN-SUFFIX,twitter.com,X专用"
    echo "  - DOMAIN-SUFFIX,twimg.com,X专用"
    echo "  - DOMAIN-SUFFIX,twimg.co,X专用"
    echo "  - DOMAIN-SUFFIX,twimg.org,X专用"
    echo "  - DOMAIN-KEYWORD,twitter,X专用"

    echo "  - DOMAIN-SUFFIX,openai.com,ChatGPT"
    echo "  - DOMAIN-SUFFIX,chatgpt.com,ChatGPT"
    echo "  - DOMAIN-SUFFIX,oaistatic.com,ChatGPT"
    echo "  - DOMAIN-SUFFIX,oaiusercontent.com,ChatGPT"
    echo "  - DOMAIN-SUFFIX,auth0.com,ChatGPT"
    echo "  - DOMAIN-KEYWORD,openai,ChatGPT"
    echo "  - DOMAIN-SUFFIX,anthropic.com,ChatGPT"
    echo "  - DOMAIN-SUFFIX,claude.ai,ChatGPT"
    echo "  - DOMAIN-KEYWORD,claude,ChatGPT"
    
    echo "  - DOMAIN-SUFFIX,t.me,T专用"
    echo "  - DOMAIN-SUFFIX,telegram.org,T专用"
    echo "  - DOMAIN-SUFFIX,telegra.ph,T专用"
    echo "  - DOMAIN-SUFFIX,telegram.me,T专用"
    echo "  - IP-CIDR,91.108.0.0/16,T专用,no-resolve"
    echo "  - IP-CIDR,149.154.0.0/16,T专用,no-resolve"

    echo "  - DOMAIN-SUFFIX,youtube.com,流媒体"
    echo "  - DOMAIN-SUFFIX,youtu.be,流媒体"
    echo "  - DOMAIN-SUFFIX,googlevideo.com,流媒体"
    echo "  - DOMAIN-SUFFIX,ytimg.com,流媒体"
    echo "  - DOMAIN-SUFFIX,netflix.com,流媒体"
    echo "  - DOMAIN-SUFFIX,nflxvideo.net,流媒体"
    echo "  - DOMAIN-SUFFIX,nflximg.net,流媒体"
    echo "  - DOMAIN-SUFFIX,nflxso.net,流媒体"
    echo "  - DOMAIN-SUFFIX,disneyplus.com,流媒体"
    echo "  - DOMAIN-SUFFIX,dssott.com,流媒体"
    echo "  - DOMAIN-SUFFIX,primevideo.com,流媒体"

    echo "  - DOMAIN-SUFFIX,cn,国内服务"
    echo "  - GEOIP,CN,国内服务"
    echo "  - MATCH,漏网之鱼"
  } > "$clash_yaml"

  local secret_dir
  secret_dir="$(ensure_secret_dir)"
  push_github_files "$secret_dir" "$sub_b64" "$clash_yaml"

  echo
  echo "================= 固定订阅地址（不变） ================="
  echo "v2rayN（base64，含 VPS 节点 + Hy2直连/限速节点）:"
  echo "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/${secret_dir}/sub.txt"
  echo
  echo "Clash Verge / Mihomo（总配置，含内置节点 + Hy2直连/限速节点）:"
  echo "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/${secret_dir}/clash.yaml"
  echo "========================================================"
  echo

  rm -rf "$tmpdir"
}

main "$@"
