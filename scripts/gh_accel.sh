#!/usr/bin/env bash
# gh_accel.sh — GitHub 网络加速工具（直连优先，镜像兜底）
# 自建/私有加速代理经本地配置文件注入（自动优先于内置镜像），无需改动本脚本：
#   ~/.config/gh-accelerator/proxies.conf   （可用环境变量 GH_ACCEL_CONFIG 覆盖路径）
# 依赖: curl, git。镜像状态易变，用前建议先跑 check。
set -uo pipefail

CONFIG_FILE="${GH_ACCEL_CONFIG:-$HOME/.config/gh-accelerator/proxies.conf}"

# 内置公共镜像梯次（按序自动降级）
DL_PROXIES=(https://ghfast.top https://gh-proxy.com)
CLONE_PROXIES=(
  "https://gitclone.com/github.com"
  "https://gh-proxy.com/https://github.com"
)
TEST_RAW="https://raw.githubusercontent.com/hunshcn/gh-proxy/master/README.md"

# ---------- 本地私有代理加载（排在公共梯次之前） ----------
# 格式（每行一条，# 注释；裸域名自动补 https://）:
#   DOWNLOAD_PROXY=https://your-proxy.example.com
#   CLONE_PROXY=https://your-proxy.example.com/https://github.com
LOCAL_DL=(); LOCAL_CLONE=()
if [ ! -f "$CONFIG_FILE" ]; then
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null \
    && cat > "$CONFIG_FILE" <<'TMPL' 2>/dev/null || true
# gh-accelerator 本地私有代理配置（机器本地文件，禁止提交到仓库）
# 每行一条，去掉行首 # 并改成你的代理地址即可生效；会自动排在公共镜像之前。
# DOWNLOAD_PROXY=https://your-proxy.example.com
# CLONE_PROXY=https://your-proxy.example.com/https://github.com
TMPL
  true
fi
if [ -f "$CONFIG_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      DOWNLOAD_PROXY=*)
        v="${line#DOWNLOAD_PROXY=}"; case "$v" in http*) ;; *) v="https://$v";; esac
        LOCAL_DL+=("$v") ;;
      CLONE_PROXY=*)
        v="${line#CLONE_PROXY=}"; case "$v" in http*) ;; *) v="https://$v";; esac
        LOCAL_CLONE+=("$v") ;;
    esac
  done < "$CONFIG_FILE"
fi
DL_PROXIES=("${LOCAL_DL[@]+"${LOCAL_DL[@]}"}" "${DL_PROXIES[@]}")
CLONE_PROXIES=("${LOCAL_CLONE[@]+"${LOCAL_CLONE[@]}"}" "${CLONE_PROXIES[@]}")

is_local() {
  local u
  for u in "${LOCAL_DL[@]+"${LOCAL_DL[@]}"}" "${LOCAL_CLONE[@]+"${LOCAL_CLONE[@]}"}"; do
    [ "$u" = "$1" ] && return 0
  done
  return 1
}

usage() {
  cat <<'EOF'
用法:
  gh_accel.sh check                    探测直连与各镜像可用性（含本地私有代理）
  gh_accel.sh dl <github-url>          下载 raw/release/archive（自动降级）
  gh_accel.sh dl --no-direct <url>     跳过直连，直接走镜像链
  gh_accel.sh clone <owner/repo> [dir] 克隆仓库（自动降级）
  gh_accel.sh clone --no-direct o/r [dir]

本地私有代理配置: $GH_ACCEL_CONFIG（默认 ~/.config/gh-accelerator/proxies.conf）
EOF
  exit 1
}

# fetch <url> <outfile> <max-sec> -> echo http_code (000=失败)
fetch() {
  local code rc
  code=$(curl -sL --max-time "$3" -o "$2" -w '%{http_code}' "$1" 2>/dev/null)
  rc=$?
  [ $rc -ne 0 ] && code=000
  echo "${code:-000}"
}

# probe <url> <max-sec> -> echo http_code (000=失败)；不跟随重定向，2xx/3xx/404 均视为存活
probe() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$2" "$1" 2>/dev/null)
  [ $? -ne 0 ] && code="000"
  echo "${code:-000}"
}

cmd_check() {
  echo "本地配置: $CONFIG_FILE ($((${#LOCAL_DL[@]} + ${#LOCAL_CLONE[@]})) 条私有代理)"
  echo "== 直连探测 =="
  for d in "api.github.com/zen" "$TEST_RAW" "codeload.github.com/hunshcn/gh-proxy/tar.gz/master" "github.com/"; do
    code=$(probe "https://$d" 8)
    case "$code" in
      200|301|302|404) echo "  ✓ $d ($code)" ;;
      *)               echo "  ✗ $d ($code)" ;;
    esac
  done
  echo "== 下载镜像（拉测试文件验内容）=="
  for p in "${DL_PROXIES[@]}"; do
    tag=""; is_local "$p" && tag="  [本地]"
    out=$(mktemp)
    code=$(fetch "$p/$TEST_RAW" "$out" 15)
    if [ "$code" = "200" ] && grep -q "gh-proxy" "$out" 2>/dev/null; then
      echo "  ✓ $p$tag"
    else
      echo "  ✗ $p$tag (http=$code)"
    fi
    rm -f "$out"
  done
  echo "== clone 镜像（ls-remote 探测公开仓库）=="
  for base in "${CLONE_PROXIES[@]}"; do
    tag=""; is_local "$base" && tag="  [本地]"
    if timeout 20 git ls-remote "$base/hunshcn/gh-proxy.git" HEAD >/dev/null 2>&1; then
      echo "  ✓ $base$tag"
    else
      echo "  ✗ $base$tag"
    fi
  done
}

cmd_dl() {
  local no_direct=0 url="${2:-$1}"
  [ "$1" = "--no-direct" ] && no_direct=1
  [[ "$url" == http* ]] || url="https://$url"
  local out="$(basename "${url%%\?*}")"
  [ -z "$out" ] && out="download.bin"

  if [ $no_direct -eq 0 ]; then
    echo "→ 直连: $url"
    code=$(fetch "$url" "$out" 60)
    if [ "$code" = "200" ] && [ -s "$out" ]; then
      echo "✅ 直连成功 -> $out ($(du -h "$out" | cut -f1))"
      return 0
    fi
    echo "  ✗ 直连失败 (http=$code)，降级镜像…"
  fi

  for p in "${DL_PROXIES[@]}"; do
    echo "→ 镜像: $p"
    code=$(fetch "$p/$url" "$out" 90)
    if [ "$code" = "200" ] && [ -s "$out" ]; then
      echo "✅ 经 $p 下载成功 -> $out ($(du -h "$out" | cut -f1))"
      return 0
    fi
    echo "  ✗ $p 失败 (http=$code)"
  done
  echo "❌ 全部通道失败。跑 'gh_accel.sh check' 看镜像状态，或找新镜像更新 DL_PROXIES"
  return 1
}

cmd_clone() {
  local no_direct=0 repo dir
  if [ "$1" = "--no-direct" ]; then
    no_direct=1; repo="$2"; dir="${3:-}"
  else
    repo="$1"; dir="${2:-}"
  fi
  repo="${repo#https://github.com/}"; repo="${repo%.git}"
  [ -z "$dir" ] && dir="$(basename "$repo")"

  if [ $no_direct -eq 0 ]; then
    echo "→ 直连: https://github.com/$repo"
    if git clone "https://github.com/$repo" "$dir"; then
      echo "✅ 直连 clone 成功 -> $dir"
      return 0
    fi
    rm -rf "$dir"
    echo "  ✗ 直连失败，降级镜像…"
  fi

  for base in "${CLONE_PROXIES[@]}"; do
    echo "→ 镜像: $base/$repo"
    if git clone "$base/$repo" "$dir"; then
      echo "✅ 经镜像 clone 成功 -> $dir"
      echo "⚠️  remote 指向镜像，push 前执行:"
      echo "   git -C $dir remote set-url origin https://github.com/$repo.git"
      return 0
    fi
    rm -rf "$dir"
    echo "  ✗ 失败"
  done
  echo "❌ 全部通道失败。跑 'gh_accel.sh check' 探测"
  return 1
}

[ $# -lt 1 ] && usage
case "$1" in
  check) cmd_check ;;
  dl)    [ $# -ge 2 ] || usage; cmd_dl "${@:2}" ;;
  clone) [ $# -ge 2 ] || usage; cmd_clone "${@:2}" ;;
  *)     usage ;;
esac
