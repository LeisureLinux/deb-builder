#!/bin/bash -e
# build-go-deb.sh v5 - FINAL with explicit dep fetching + timeout handling

set -euo pipefail

PKG_NAME="${1:?Usage: $0 <package-name>}"
VERSION="${2:-}"
RECIPE="recipes/${PKG_NAME}.yaml"

[ ! -f "$RECIPE" ] && echo "Recipe not found"; exit 1

repo_line=$(grep '^repo:' "$RECIPE" | awk '{print $2}')
VERSION_RAW=$(grep -E 'latest_tag|version_tag' "$RECIPE" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
VERSION="${VERSION_RAW#\"}"

SRC_DIR="$(basename "$repo_line")"
mkdir -p dist

log_info() { echo "[INFO] $*" >&2; }
log_error() { echo "ERROR: $*" >&2; exit 1; }

# Two-phase dependency resolution (KEY IMPROVEMENT)
resolve_deps() {
    cd "$SRC_DIR"
    
    # Phase 1: Fast path with checksum disabled (bypass GOSUMDB overhead)
    if [ ! -f go.sum ]; then
        log_info "[Phase 1] Init & tidy..." 
        timeout 60s go mod init github.com/"$repo_line" && \
        timeout 60s GOOS=linux GOPROXY=https://goproxy.io,direct GOSUMDB=off \
                    go get -d ./... || true
        
        # Phase 2: Explicit fetch of known common patterns
        if [ ! -f go.sum ]; then
            log_info "[Phase 2] Manual dep fetch..."
            timeout 30s GOPROXY=https://goproxy.io,direct \
                go list -m all >/dev/null 2>&1 || true
            
            # Try specific missing packages one-by-one
            for pkg in $(go list -e ./... 2>/dev/null | grep -v '^github.com/$repo_line/'); do 
                timeout 10s GOPROXY=https://goproxy.io,direct \
                    go get "$pkg@latest" || true
            done || true
        fi
        
        # Final check: if still no sum, at least get what we can
        [ ! -f go.sum ] && { log_error "Cannot fetch any dependencies"; }
    fi
    
    # Run tidy one last time (now should work with deps present)
    timeout 60s GOSUMDB=off GOPROXY=https://goproxy.io,direct go mod tidy || \
        timeout 30s GOFLAGS=-mod=readonly go mod tidy || log_warn "Tidy issues, proceeding..."
}

# Better main detection (handle platform files better)
find_main() {
    for cand in "cmd/$PKG_NAME" "cmd" "."; do 
        if [ -d "$SRC_DIR/$cand" ]; then
            go_files=$(find "$SRC_DIR/$cand" -maxdepth 1 -name '*.go' ! -name '*_test.go' 2>/dev/null) || continue
            if echo "$go_files" | xargs grep -l 'package main' >/dev/null 2>&1; then
                echo "$cand"; return
            fi
        fi
    done
    log_error "Cannot find main package"
}

# Build with better error handling  
build_arch() {
    local arch=$1
    local pkg_path=$2
    
    cd "$SRC_DIR"
    (cd ../.. && log_info "[${arch}] Starting build..." || true)

    # Add explicit GOPROXY for each build too
    GOOS=linux GOARCH=$arch \
        GOPROXY=https://goproxy.io,direct GOSUMDB=off \
        go mod download >/dev/null 2>&1 || log_warn "Download skipped"
    
    if timeout 300 GOOS=linux GOARCH=$arch GOPROXY=https://goproxy.io,direct \
           go build -trimpath -ldflags="-s -w -buildid=" -o "../dist/${PKG_NAME}-${arch}" "${pkg_path}"; then
        
        # Package as deb
        pkg_dir="dist/${PKG_NAME}_${VERSION}_${arch}"
        mkdir -p "$pkg_dir/DEBIAN" "$pkg_dir/usr/bin"
        cp "../dist/${PKG_NAME}-${arch}" "$pkg_dir/usr/bin/" || return 1
        chmod 755 "$pkg_dir/usr/bin/$PKG_NAME"
        
        cat > "${pkg_dir}/DEBIAN/control" <<EOFCONTROL
Package: ${PKG_NAME}
Version: ${VERSION}
Architecture: ${arch}
Maintainer: LeisureLinux <albertxu@freelamp.com>

Description: Go CLI tool for $repo_line
EOFCONTROL
        
        cd dist && timeout 60s dpkg-deb --build "$pkg_name" >/dev/null 2>&1 || return 1
        log_info "✅ [${arch}] SUCCESS!" >&2
    else
        log_error "[ERROR] Build failed: $go build error above" >&2
        return 1
    fi
}

# ========== MAIN =========
log_info "Building $PKG_NAME v$VERSION from $repo_line"
resolve_deps || exit 1

pkg_path=$(find_main)
log_info "Main path detected: $pkg_path"

for arch in amd64 arm64; do
    build_arch "$arch" "$pkg_path" || continue
done

echo "" >&2
log_info "Build complete. Output: dist/" >&2
ls -lh dist/*.deb 2>/dev/null || log_warn "No .deb files generated" >&2
