#!/usr/bin/env bash
# gh_accel.sh — GitHub 网络加速工具（直连优先，镜像兑底）
# 镜像梯次按序自动降级；如有自建可信代理，追加到数组末尾即可
# 依赖: curl, git。镜像状态易变，用前建议先跑 check。
set -uo pipefail

DL_PROXIES=(ghfast.top gh-proxy.com)
CLONE_PROXIES=(
  "https://gitclone.com/github.com"
  "https://gh-proxy.com/https://github.com"
)
TEST_RAW="https://raw.githubusercontent.com/hunshcn/gh-proxy/master/README.md"

usage() {
  cat <<'EOF'
用法:
  gh_accel.sh check                    探测直连与各镜像可用性
  gh_accel.sh dl <github-url>          下载 raw/release/archive（自动降级）
  gh_accel.sh dl --no-direct <url>     跳过直连，直接走镜像链
  gh_accel.sh clone <owner/repo> [dir] 克隆仓库（自动降级）
  gh_accel.sh clone --no-direct o/r [dir]
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
  echo "== 直连探测 =="
  for d in "api.github.com/zen" "$TEST_RAW" "codeload.github.com/hunshcn/gh-proxy/tar.gz/master" "github.com/"; do
    code=$(probe "https://$d" 8)
    case "$code" in
      200|301|302|404) echo "  ✓ $d ($code)" ;;
      *)               echo "  ✗ $d ($code)" ;;
    esac
  done
  echo "== 下载镜像（拉测试文件验内容）=="
  for p in "${DL_PROXIES[@]}" ghproxy.net; do
    out=$(mktemp)
    code=$(fetch "https://$p/$TEST_RAW" "$out" 15)
    if [ "$code" = "200" ] && grep -q "gh-proxy" "$out" 2>/dev/null; then
      echo "  ✓ $p"
    else
      echo "  ✗ $p (http=$code)"
    fi
    rm -f "$out"
  done
  echo "== clone 镜像（ls-remote 探测公开仓库）=="
  for base in "${CLONE_PROXIES[@]}"; do
    if timeout 20 git ls-remote "$base/hunshcn/gh-proxy.git" HEAD >/dev/null 2>&1; then
      echo "  ✓ $base"
    else
      echo "  ✗ $base"
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
    echo "→ 镜像: https://$p/"
    code=$(fetch "https://$p/$url" "$out" 90)
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
