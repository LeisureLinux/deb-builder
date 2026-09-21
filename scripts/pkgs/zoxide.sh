#!/bin/bash
# zoxide —— Rust "smarter cd"（musl 全静态，amd64/arm64）
#
# 由 scripts/build-go-deb.sh 的 build_script 机制调用。已导出环境变量见
# scripts/pkgs/common.sh 头部注释。
#
# 为什么必须自建（不用通用 language: rust 分支）：
#   需要 musl 全静态（不依赖发行版 glibc），通用分支固定 gnu triple。
#   与 yazi 保持一致：yazi 的目录跳转插件直接 exec `zoxide`，两者都做成静态，
#   装在任何发行版/任何 glibc 版本上都能用。
#
# 构建方式：cargo build --locked --release --target <musl-triple>，
#   CC_<triple>=musl-gcc 只用于编 vendored C（zoxide 本身无 C 依赖，保留以备
#   依赖变化）；链接走 rustup 自带 musl self-contained CRT，产物 static-pie。
#   不启用上游可选的 rust-lld/unstable rustflags —— 见 scripts/pkgs/yazi.sh
#   里的实测说明（rustc 1.98 裸调 rust-lld 时不转译 -Wl, 参数，必炸）。
#
# 包内容：/usr/bin/zoxide + man（上游自带，无需生成）+ shell 集成/补全
#   （contrib/completions 是上游随仓库维护的静态文件，build.rs 不生成）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
. "$HERE/common.sh"

SRC="$(tmpabs)/zoxide-src-$(_ts)"
clone_upstream "$SRC"
cd "$SRC"

# 结束时清理临时目录（源码树 + deb-root），避免 CI/本地累积撑爆 /tmp
cleanup_tmp() {
  rm -rf "$(tmpabs)"/zoxide-src-* "$(tmpabs)"/zoxide-deb-root-* 2>/dev/null || true
}
trap cleanup_tmp EXIT

command -v cargo >/dev/null || { curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; }
export PATH="$HOME/.cargo/bin:$PATH"

# C 编译器显式指定：不指定的话 cc-rs 会拿 cargo config 里的 linker（rust-lld）
# 当 C 编译器兜底，lld 不能编 C。AR 同理。
export CC_x86_64_unknown_linux_musl="${CC_x86_64_unknown_linux_musl:-musl-gcc}"
export AR_x86_64_unknown_linux_musl="${AR_x86_64_unknown_linux_musl:-ar}"
export CC_aarch64_unknown_linux_musl="${CC_aarch64_unknown_linux_musl:-musl-gcc}"
export AR_aarch64_unknown_linux_musl="${AR_aarch64_unknown_linux_musl:-ar}"

ensure_musl_tools() {
  if ! command -v musl-gcc >/dev/null 2>&1; then
    echo "🧰 安装 musl-tools ..." >&2
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -qq && sudo apt-get install -y -qq musl-tools >/dev/null
    else
      apt-get update -qq && apt-get install -y -qq musl-tools >/dev/null
    fi
  fi
}

arch_to_triple() {
  case "$1" in
    amd64) echo x86_64-unknown-linux-musl ;;
    arm64) echo aarch64-unknown-linux-musl ;;
    *)     echo "" ;;
  esac
}

# ldd/file 双重校验：ldd 对静态二进制会打印 "statically linked" 且退出码为 0，
# 所以不能拿退出码判断，要看输出里有没有 .so / 动态 loader。
assert_static() {
  local bin="$1" out=""
  if command -v ldd >/dev/null 2>&1; then
    out="$(ldd "$bin" 2>&1 || true)"
  fi
  if echo "$out" | grep -qE '\.so[^/]*[[:space:]]*=>|ld-linux|ld-musl'; then
    echo "❌ $bin 是动态链接:" >&2
    echo "$out" | head -5 >&2
    return 1
  fi
  file "$bin" | grep -qE "static-pie|statically linked" || {
    echo "⚠️  file 未识别为静态（可能是新 file 语法），继续。输出: $(file "$bin")" >&2
  }
  echo "✔ $(basename "$bin"): 全静态 ($(file "$bin" | grep -oE 'static-pie|statically linked' | head -1))" >&2
}

FAILED=()
for arch in $(echo "$ARCHS_CSV" | tr ',' ' '); do
  [[ -z "$arch" ]] && continue
  TRIPLE="$(arch_to_triple "$arch")"
  if [[ -z "$TRIPLE" ]]; then
    echo "⚠️  zoxide musl 构建不支持 ${arch}，跳过" >&2
    FAILED+=("$arch"); continue
  fi

  echo "🚀 Building zoxide for ${arch} (${TRIPLE}) ..." >&2
  ensure_musl_tools
  rustup target add "$TRIPLE" >/dev/null 2>&1 || true

  # 本地 x64 手工编 arm64 时才需要交叉工具链；CI 用原生 arm64 runner
  EXTRA_ENV=()
  if [[ "$(uname -m)" != "aarch64" && "$arch" == "arm64" ]]; then
    if command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
      EXTRA_ENV=("CC_aarch64_unknown_linux_musl=aarch64-linux-musl-gcc" \
                 "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-musl-gcc")
    else
      echo "❌ x64 主机上编 arm64 需要 aarch64-linux-musl-gcc（musl-cross-make）；CI 原生 runner 无此需求" >&2
      FAILED+=("$arch"); continue
    fi
  fi

  if ! env "${EXTRA_ENV[@]}" \
      cargo build --locked --release --target "$TRIPLE"; then
    echo "❌ cargo build failed for ${arch}" >&2
    FAILED+=("$arch"); continue
  fi

  BIN="target/${TRIPLE}/release/zoxide"
  [[ -f "$BIN" ]] || { echo "❌ binary not found: $BIN" >&2; FAILED+=("$arch"); continue; }
  assert_static "$BIN"

  # --- 组包 ---
  ROOT="$(tmpabs)/zoxide-deb-root-${arch}-$(_ts)"
  rm -rf "$ROOT"; mkdir -p "$ROOT/usr/bin"

  install -m755 "$BIN" "$ROOT/usr/bin/zoxide"

  # man：上游随仓库维护（man/man1/zoxide*.1），已 gzip 压缩与否都按原样装
  if compgen -G "man/man1/zoxide*.1*" >/dev/null; then
    for m in man/man1/zoxide*.1*; do
      install -Dm644 "$m" "$ROOT/usr/share/man/man1/$(basename "$m")"
    done
  fi

  # 补全：contrib/completions/ 下是上游维护好的静态文件
  [[ -f contrib/completions/zoxide.bash ]] && \
    install -Dm644 contrib/completions/zoxide.bash "$ROOT/usr/share/bash-completion/completions/zoxide"
  [[ -f contrib/completions/zoxide.fish ]] && \
    install -Dm644 contrib/completions/zoxide.fish "$ROOT/usr/share/fish/vendor_completions.d/zoxide.fish"
  [[ -f contrib/completions/_zoxide ]] && \
    install -Dm644 contrib/completions/_zoxide "$ROOT/usr/share/zsh/vendor-completions/_zoxide"

  deb_write_control "$ROOT" "$arch" \
    "A smarter cd command for your terminal" \
    "zoxide is a smarter cd command. It remembers which directories you use most" \
    "frequently, so you can jump to them in just a few keystrokes." \
    "Used by yazi's z (jump) plugin; load the shell integration with" \
    "'eval \"\$(zoxide init <shell>)\"' in your rc file." \
    "Statically linked against musl libc; runs on any distribution regardless of glibc version." \
    "Upstream: ${REPO_LINE} @ ${COMMIT_HASH:0:7}"
  deb_apply_extra "$ROOT"
  deb_finalize "$ROOT" "$arch" >/dev/null
done

# 与 build-go-deb.sh 语义一致：全部架构失败才算失败
if (( ${#FAILED[@]} > 0 )) && ! compgen -G "${OUTPUT_DIR}/${PKG_NAME}_${FINAL_VERSION}_*.deb" >/dev/null; then
  echo "💥 zoxide: all arches failed: ${FAILED[*]}" >&2
  exit 1
fi
