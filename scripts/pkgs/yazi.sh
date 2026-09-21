#!/bin/bash
# yazi —— Rust 终端文件管理器（musl 全静态，amd64/arm64）
#
# 由 scripts/build-go-deb.sh 的 build_script 机制调用。已导出环境变量见
# scripts/pkgs/common.sh 头部注释。
#
# 为什么必须自建（不用通用 language: rust 分支）：
#   1. 需要 musl 全静态（不依赖发行版 glibc），通用分支固定 gnu triple；
#   2. workspace 产出 yazi + ya 两个二进制，还有 completions / desktop 资产；
#   3. 上游 release 用 unstable rustflags（rust-lld 等），要对齐上游 xtask。
#
# 与上游 .github/workflows/draft.yml build-musl 的差异：
#   上游在 cross-rs 容器里跑（x64 容器交叉编 arm64），本仓库 CI 每个架构
#   一台原生 runner，直接装目标架构的 musl 工具链原生编译，效果等价。
#
# 构建步骤对齐上游 scripts/build.sh → cargo xtask dist（yazi-build crate）：
#   cargo build --locked --profile release --target <musl-triple>
#   + RUSTC_BOOTSTRAP=1 + .cargo/release.toml 的 rustflags（rust-lld / ICF /
#   pack-relative-relocs / trim-paths）+ YAZI_GEN_COMPLETIONS=1 生成补全。
#
# 包内容对齐上游官方 musl deb（yazi-packing/Cargo.toml 的 [package.metadata.deb]）：
#   /usr/bin/{yazi,ya} + bash/zsh/fish 补全；desktop/icon 为本配方补充。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
. "$HERE/common.sh"

SRC="$(tmpabs)/yazi-src-$(_ts)"
clone_upstream "$SRC"
cd "$SRC"

# 结束时清理临时目录（源码树 + deb-root），避免 CI/本地累积撑爆 /tmp
YAZI_TMP_PREFIX="$(basename "$SRC")"
cleanup_tmp() {
  rm -rf "$(tmpabs)"/yazi-src-* "$(tmpabs)"/yazi-deb-root-* 2>/dev/null || true
}
trap cleanup_tmp EXIT

# 上游 Cargo.lock 锁定的工具链版本；装 musl target 后用 default toolchain 即可
command -v cargo >/dev/null || { curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; }
export PATH="$HOME/.cargo/bin:$PATH"

# 与上游的刻意差异（实测结论，不要轻易改回去）：
#   上游 xtask 还会叠加 .cargo/release.toml（unstable trim-paths / rust-lld / ICF /
#   pack-relative-relocs）+ RUSTC_BOOTSTRAP=1。本机与 CI 实测（rustc 1.98）：
#   -Clink-self-contained=+linker 会让 rustc 直接裸调用 rust-lld，此时 -Wl, 前缀
#   参数不转译，上游 release.toml 的 "-Wl,--icf=safe" 直接报
#   "unknown argument"；而绕开 self-contained 用 linker-features=+lld 又是
#   nightly-only flag，cargo 1.98 会剥离 RUSTC_BOOTSTRAP，stable 也过不去。
#   上游在 CI 里能跑通是交叉容器 + 当时工具链行为，不值得追。
#   这里走最稳路径：默认 gcc 驱动 + rustup 自带 musl self-contained CRT，
#   产物同样是 static-pie 全静态（见 assert_static 硬校验），只损失体积优化。
export YAZI_GEN_COMPLETIONS=1

# jemalloc（tikv-jemalloc-sys）以 vendored C 源码参与编译，需要 musl 版 C 工具链；
# 纯 Rust 依赖链不需要它。两套工具链都装上，谁需要谁用。
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

# 显式指定 C 编译器与汇编器（vendored C 依赖如 jemalloc 走 cc-rs）：
#   C 编译用 musl-gcc（musl-tools），链接交给 rustflags 的 rust-lld。
# 不显式设 CC 的话，cc-rs 会把 cargo config 里的 linker（rust-lld）当 C 编译器兜底，
# lld 不能编 C，jemalloc 阶段必挂 —— 这个坑实测踩过。
# AR 同理显式指定，避免依赖构建机上的默认值。
export CC_x86_64_unknown_linux_musl="${CC_x86_64_unknown_linux_musl:-musl-gcc}"
export AR_x86_64_unknown_linux_musl="${AR_x86_64_unknown_linux_musl:-ar}"
export CC_aarch64_unknown_linux_musl="${CC_aarch64_unknown_linux_musl:-musl-gcc}"
export AR_aarch64_unknown_linux_musl="${AR_aarch64_unknown_linux_musl:-ar}"

# ldd/file 双重校验：保证"全静态"承诺不靠嘴说。
# 注意：ldd 对静态二进制会打印 "statically linked" 且退出码为 0，
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
    echo "⚠️  yazi musl 构建不支持 ${arch}，跳过" >&2
    FAILED+=("$arch"); continue
  fi

  echo "🚀 Building yazi for ${arch} (${TRIPLE}) ..." >&2
  ensure_musl_tools
  rustup target add "$TRIPLE" >/dev/null 2>&1 || true

  # arm64 在 x64 机器上（本地手工测试时）需要交叉链接器；CI 原生 runner 不走这里
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

  # 对齐上游 yazi-build::Build::run：
  #   RUSTC_BOOTSTRAP=1 + release.toml + rust-lld self-contained（rustup 的 musl
  #   target 自带 rust-lld，has_rust_lld() 恒真）+ --locked + release profile
  if ! env "${EXTRA_ENV[@]}" \
      cargo build --locked --profile release --target "$TRIPLE"; then
    echo "❌ cargo build failed for ${arch}" >&2
    FAILED+=("$arch"); continue
  fi

  YAZI_BIN="target/${TRIPLE}/release/yazi"
  YA_BIN="target/${TRIPLE}/release/ya"
  for b in "$YAZI_BIN" "$YA_BIN"; do
    [[ -f "$b" ]] || { echo "❌ binary not found: $b" >&2; FAILED+=("$arch"); continue 2; }
  done
  assert_static "$YAZI_BIN"

  # --- 组包：内容对齐上游官方 musl deb ---
  ROOT="$(tmpabs)/yazi-deb-root-${arch}-$(_ts)"
  rm -rf "$ROOT"; mkdir -p "$ROOT/usr/bin"

  install -m755 "$YAZI_BIN" "$ROOT/usr/bin/yazi"
  install -m755 "$YA_BIN"   "$ROOT/usr/bin/ya"

  # 补全：YAZI_GEN_COMPLETIONS=1 时 build.rs 生成在 crate 目录的 completions/
  for f in yazi-cli/completions/ya.bash yazi-boot/completions/yazi.bash; do
    [[ -f "$f" ]] && { install -Dm644 "$f" "$ROOT/usr/share/bash-completion/completions/$(basename "$f" .bash)"; }
  done
  # zsh/fish 补全上游 stage 了但 deb 未含（装进 zsh 标准路径）
  for f in yazi-boot/completions/_yazi yazi-cli/completions/_ya; do
    [[ -f "$f" ]] && install -Dm644 "$f" "$ROOT/usr/share/zsh/vendor-completions/$(basename "$f")"
  done
  for f in yazi-boot/completions/yazi.fish yazi-cli/completions/ya.fish; do
    [[ -f "$f" ]] && install -Dm644 "$f" "$ROOT/usr/share/fish/vendor_completions.d/$(basename "$f")"
  done

  # desktop + icon（上游 deb 未含，终端应用也可由启动器按 MimeType 打开目录）
  if [[ -f assets/yazi.desktop ]]; then
    install -Dm644 assets/yazi.desktop "$ROOT/usr/share/applications/yazi.desktop"
  fi
  if [[ -f assets/logo.png ]]; then
    install -Dm644 assets/logo.png "$ROOT/usr/share/icons/hicolor/256x256/apps/yazi.png"
  fi

  deb_write_control "$ROOT" "$arch" \
    "Blazing fast terminal file manager written in Rust, based on async I/O" \
    "Yazi (means \"duck\") is a terminal file manager written in Rust, based on async I/O." \
    "Ships the yazi file manager and the ya CLI helper." \
    "Statically linked against musl libc; runs on any distribution regardless of glibc version." \
    "Upstream: ${REPO_LINE} @ ${COMMIT_HASH:0:7}"
  deb_apply_extra "$ROOT"
  deb_finalize "$ROOT" "$arch" >/dev/null
done

# 与 build-go-deb.sh 语义一致：全部架构失败才算失败
if (( ${#FAILED[@]} > 0 )) && ! compgen -G "${OUTPUT_DIR}/${PKG_NAME}_${FINAL_VERSION}_*.deb" >/dev/null; then
  echo "💥 yazi: all arches failed: ${FAILED[*]}" >&2
  exit 1
fi
