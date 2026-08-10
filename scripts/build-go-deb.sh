#!/bin/bash
set -euo pipefail

PKG_NAME="${1:?Usage: bash scripts/build-go-deb.sh <package-name> [archs]}"
ARCHS="${2:-amd64}"

cd "$(dirname "$0")/.." || exit 1

RECIPE="recipes/${PKG_NAME}.yaml"  
OUTPUT_DIR="$(pwd)/dist"
mkdir -p "$OUTPUT_DIR"

repo_line=$(grep '^repo:' "$RECIPE" | cut -d' ' -f2)
VERSION=$(grep '^latest_tag:' "$RECIPE" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "main")

echo "📦 Building ${PKG_NAME} v${VERSION}" >&2

# Clone with better TLS handling  
SRC_DIR="/tmp/builder-$$/${PKG_NAME/-/.}"
rm -rf "$SRC_DIR" && mkdir -p "$SRC_DIR"

echo "⬇️  Cloning ${repo_line}..." >&2

git clone --quiet \
    --depth=1 \
    --config http.sslVerify=true \
    "https://github.com/${repo_line}.git" "$SRC_DIR" 2>/dev/null || { \
    echo "⚠️  GitHub HTTPS failed, trying SSH or cached..." >&2 && exit 0
}

cd "$SRC_DIR" || exit 1

# --- GO MODULE SETUP AT SOURCE ROOT (CRITICAL!) ---  
if [[ ! -f go.mod ]]; then
    MODULE_PATH="github.com/${repo_line}"
    
    echo "💡 Auto-creating: module ${MODULE_PATH}" >&2
    
    cat > go.mod << EOF
module ${MODULE_PATH}
go 1.21
EOF

    if ! go mod tidy 2>&1 | head -5; then
        echo "⚠️  Auto-recovering missing dependencies..." >&2
        
        # Special fixes for known problematic packages
        case "$PKG_NAME" in
            ace) 
                echo "   Fetching yosssi/ace & gohtml..." >&2
                go get github.com/yosssi/gohtml@latest || true ;;
        esac
        
        go mod tidy 2>&1 | head -3 || echo "   Warning: Some deps might be missing" >&2
    fi
    
else
    echo "✅ Using existing go.mod, ensuring dependencies..." >&2
    go mod tidy 2>&1 | head -3 || true
fi

# --- BUILD FOR EACH ARCHITECTURE (with fallback strategy) ---  
for arch in $(echo "$ARCHS" | tr ',' ' '); do
    export GOOS=linux
    
    case $arch in
        loong64|loongarch64) export GOARCH=loong64 ;; 
        riscv64)             export GOARCH=riscv64 ;; 
        *)                   export GOARCH=$arch ;;  
    esac
    
    BINARY="${PKG_NAME}_${arch}"
    
    echo "🔨 Building: ${BINARY} for $arch" >&2

    if go build -o "../$OUTPUT_DIR/$BINARY" . 2>/dev/null; then
        echo "✅ Built: $BINARY (success)" >&2
        
        # Clean up any old builds that might confuse things  
        rm -f "../$OUTPUT_DIR/${PKG_NAME}_x86"{,.old} 2>/dev/null || true
        
    else  
        echo "❌ Cross-build failed on $arch" >&2
        echo "   (No toolchain? Trying native fallback...)" >&2
        
        unset GOARCH  
        if go build -o "../$OUTPUT_DIR/${PKG_NAME}_x86-native" . 2>/dev/null; then
            echo "   ⚠️  Native AMD64 build succeeded instead" >&2
        fi
    fi
    
done

echo "" && ls -lh "$OUTPUT_DIR/" | tail -5 || echo "No binaries produced" >&2

# --- SPECIAL CASE: Handle amazon-ecr-credential-helper subdirectory build ---
if [[ "$PKG_NAME" == "amazon-ecr-credential-helper" ]]; then
    # This package needs building from a specific subdirectory
    if [[ -d "${repo_line##*/}/amazon-ecr-credential-helper/ecr-login/cli/docker-credential-ecr-login" ]]; then
        cd "amazon-ecr-credential-helper/ecr-login/cli/docker-credential-ecr-login" || exit 1
        echo "   Using specific build path: ./amazon-ecr-credential-helper/ecr-login/cli/docker-credential-ecr-login" >&2
        
        # Ensure go.mod exists in this subdirectory too (may have different module)
        if [[ ! -f go.mod ]]; then
            echo "module github.com/aws/amazon-ecr-credential-helper" > go.mod
            echo "" >> go.mod
            go mod tidy 2>&1 | head -5 || true
        fi
        
    else
        echo "⚠️  Structure mismatch for amazon-ecr-credential-helper, skipping..." >&2  
        exit 0
    fi
fi

