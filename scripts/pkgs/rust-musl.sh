#!/bin/bash
# 通用 Rust musl 全静态构建（amd64/arm64）—— debian.griffo.io 迁移用
#
# 由 scripts/build-go-deb.sh 的 build_script 机制调用。已导出环境变量见
# scripts/pkgs/common.sh 头部注释。
#
# 为什么不用通用 language: rust 分支：那个分支固定 gnu triple，产物动态链接
# glibc，只在与其构建发行版相同的系统上可用（实测我们仓库早期的 fd/ripgrep
# 就是这种，bookworm 装 trixie 编的包会跑不起来）。本仓库新增的 Rust 包统一
# 走 musl 全静态，与 yazi/zoxide 一致。
#
# 构建方式：cargo build --locked --release --target <musl-triple>
#   - CC_<triple>=musl-gcc：编 vendored C（jemalloc 等）用；不指定的话 cc-rs
#     会拿 cargo config 的 linker（rust-lld）当 C 编译器兜底，lld 不能编 C。
#   - 链接走 rustup 自带 musl self-contained CRT，产物 static-pie（有硬校验）。
#   - 不启用上游常见的 rust-lld / unstable rustflags：rustc 1.98 在
#     -Clink-self-contained=+linker 下裸调 rust-lld，不转译 -Wl, 前缀参数，
#     会直接报 unknown argument（scripts/pkgs/yazi.sh 里有完整实测记录）。
#   - jemalloc 等 autoconf 类依赖在 arm64 原生 runner 上会因 musl 动态链接的
#     测试程序跑不起来而误判特性，预置 je_cv_* 缓存变量跳过探测。
#
# recipe 可声明的可选字段（都通过 build-go-deb.sh 传入的环境变量读取）：
#   rust_bins: 二进制名列表（块列表），默认取包名
#   rust_package: cargo -p 参数（workspace 里指定成员），默认不指定
#   rust_features: 逗号分隔的 features，默认无
#   rust_all_bins: true 时把 workspace 全部成员都编（默认只编指定包）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
. "$HERE/common.sh"

# --- 读 recipe 的可选字段 ---
yaml_list() { # 读块列表字段，输出空格分隔
  awk -v f="$1" '
    $0 ~ "^"f":"   {flag=1; next}
    flag && /^[^[:space:]]/ {exit}
    flag && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/"/, ""); printf "%s ", $0
    }' "${RECIPE:?RECIPE 未设置}"
}
yaml_val() { grep "^$1:" "${RECIPE:?RECIPE 未设置}" 2>/dev/null | head -n1 | sed "s/^$1:[[:space:]]*//" | tr -d '"' || true; }

BINS="$(yaml_list rust_bins)"
[[ -z "${BINS// /}" ]] && BINS="$PKG_NAME"
CARGO_PKG="$(yaml_val rust_package)"
FEATURES="$(yaml_val rust_features)"
ALL_BINS="$(yaml_val rust_all_bins)"

SRC="$(tmpabs)/${PKG_NAME}-src-$(_ts)"
clone_upstream "$SRC"
cd "$SRC"

cleanup_tmp() {
  rm -rf "$(tmpabs)"/${PKG_NAME}-src-* "$(tmpabs)"/${PKG_NAME}-deb-root-* 2>/dev/null || true
}
trap cleanup_tmp EXIT

command -v cargo >/dev/null || { curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; }
export PATH="$HOME/.cargo/bin:$PATH"

export CC_x86_64_unknown_linux_musl="${CC_x86_64_unknown_linux_musl:-musl-gcc}"
export AR_x86_64_unknown_linux_musl="${AR_x86_64_unknown_linux_musl:-ar}"
export CC_aarch64_unknown_linux_musl="${CC_aarch64_unknown_linux_musl:-musl-gcc}"
export AR_aarch64_unknown_linux_musl="${AR_aarch64_unknown_linux_musl:-ar}"

# jemalloc 等 vendored C 依赖的 autoconf 探测在 arm64 runner 上会误判：
# 测试程序是 musl 动态链接的，在 glibc runner 上跑不起来 → 全部判 no。
# aarch64 musl 工具链实际都支持，直接预置答案跳过探测。
export je_cv_c11_atomics=yes
export je_cv_gcc_atomic_atomics=yes
export je_cv_gcc_sync_atomics=yes
export je_cv_asm_volatile=yes
export je_cv_int128=yes

ensure_musl_tools() {
  if ! command -v musl-gcc >/dev/null 2>&1; then
    echo "🧰 安装 musl-tools ..." >&2
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -qq && sudo apt-get install -y -qq musl-tools >/dev/null
    else
      apt-get update -qq && apt-get install -y -qq musl-tools >/dev/null
    fi
  fi
  # openssl vendored（atuin 的 vendored-tls 等）从源码编 OpenSSL 需要 perl/make
  if [[ -n "$FEATURES" && "$FEATURES" == *vendored* ]] && ! command -v perl >/dev/null 2>&1; then
    echo "🧰 安装 perl（vendored openssl 需要）..." >&2
    sudo apt-get install -y -qq perl make >/dev/null 2>&1 || true
  fi
  export OPENSSL_STATIC=1   # vendored openssl 强制静态链接
}

arch_to_triple() {
  case "$1" in
    amd64) echo x86_64-unknown-linux-musl ;;
    arm64) echo aarch64-unknown-linux-musl ;;
    *)     echo "" ;;
  esac
}

assert_static() {
  local bin="$1" out=""
  if command -v ldd >/dev/null 2>&1; then out="$(ldd "$bin" 2>&1 || true)"; fi
  if echo "$out" | grep -qE '\.so[^/]*[[:space:]]*=>|ld-linux|ld-musl'; then
    echo "❌ $bin 是动态链接:" >&2; echo "$out" | head -5 >&2; return 1
  fi
  echo "✔ $(basename "$bin"): 全静态 ($(file "$bin" | grep -oE 'static-pie|statically linked' | head -1))" >&2
}

FAILED=()
for arch in $(echo "$ARCHS_CSV" | tr ',' ' '); do
  [[ -z "$arch" ]] && continue
  TRIPLE="$(arch_to_triple "$arch")"
  if [[ -z "$TRIPLE" ]]; then
    echo "⚠️  ${PKG_NAME} musl 构建不支持 ${arch}，跳过" >&2
    FAILED+=("$arch"); continue
  fi

  echo "🚀 Building ${PKG_NAME} for ${arch} (${TRIPLE}) ..." >&2
  ensure_musl_tools
  rustup target add "$TRIPLE" >/dev/null 2>&1 || true

  EXTRA_ENV=()
  if [[ "$(uname -m)" != "aarch64" && "$arch" == "arm64" ]]; then
    if command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
      EXTRA_ENV=("CC_aarch64_unknown_linux_musl=aarch64-linux-musl-gcc" \
                 "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-musl-gcc")
    else
      echo "❌ x64 主机编 arm64 需要 aarch64-linux-musl-gcc；CI 用原生 arm64 runner" >&2
      FAILED+=("$arch"); continue
    fi
  fi

  CARGO_ARGS=(build --locked --release --target "$TRIPLE")
  [[ -n "$CARGO_PKG" ]] && CARGO_ARGS+=(-p "$CARGO_PKG")
  [[ -n "$FEATURES" ]] && CARGO_ARGS+=(--features "$FEATURES")

  if ! env "${EXTRA_ENV[@]}" cargo "${CARGO_ARGS[@]}"; then
    echo "❌ cargo build failed for ${arch}" >&2
    FAILED+=("$arch"); continue
  fi

  # --- 组包 ---
  ROOT="$(tmpabs)/${PKG_NAME}-deb-root-${arch}-$(_ts)"
  rm -rf "$ROOT"; mkdir -p "$ROOT/usr/bin"

  FOUND=0
  for b in $BINS; do
    if [[ -f "target/${TRIPLE}/release/${b}" ]]; then
      install -m755 "target/${TRIPLE}/release/${b}" "$ROOT/usr/bin/${b}"
      assert_static "$ROOT/usr/bin/${b}"
      FOUND=1
    fi
  done
  if (( FOUND == 0 )); then
    echo "❌ 未找到任何预期二进制（${BINS}）于 target/${TRIPLE}/release/" >&2
    ls "target/${TRIPLE}/release/" 2>/dev/null | head -10 >&2
    FAILED+=("$arch"); continue
  fi

  # 顺手装上上游仓库里现成的资产（man / 补全），没有就跳过
  if [[ -d man ]]; then
    while IFS= read -r m; do
      install -Dm644 "$m" "$ROOT/usr/share/man/man1/$(basename "$m")"
    done < <(find man -name '*.1' -o -name '*.1.gz' 2>/dev/null)
  fi
  for c in completions/$PKG_NAME.bash completions/$PKG_NAME.fish completions/_$PKG_NAME \
           contrib/completions/$PKG_NAME.bash contrib/completions/$PKG_NAME.fish contrib/completions/_$PKG_NAME; do
    [[ -f "$c" ]] || continue
    case "$c" in
      *.bash) install -Dm644 "$c" "$ROOT/usr/share/bash-completion/completions/$PKG_NAME" ;;
      *.fish) install -Dm644 "$c" "$ROOT/usr/share/fish/vendor_completions.d/$PKG_NAME.fish" ;;
      _*)     install -Dm644 "$c" "$ROOT/usr/share/zsh/vendor-completions/$(basename "$c")" ;;
    esac
  done

  deb_write_control "$ROOT" "$arch" \
    "$(yaml_val summary)" \
    "$(yaml_val summary)" \
    "Built from source by deb-builder, published to repo.freelamp.com." \
    "Statically linked against musl libc; runs on any distribution regardless of glibc version." \
    "Upstream: ${REPO_LINE} @ ${COMMIT_HASH:0:7}"
  deb_apply_extra "$ROOT"
  deb_finalize "$ROOT" "$arch" >/dev/null
done

if (( ${#FAILED[@]} > 0 )) && ! compgen -G "${OUTPUT_DIR}/${PKG_NAME}_${FINAL_VERSION}_*.deb" >/dev/null; then
  echo "💥 ${PKG_NAME}: all arches failed: ${FAILED[*]}" >&2
  exit 1
fi
