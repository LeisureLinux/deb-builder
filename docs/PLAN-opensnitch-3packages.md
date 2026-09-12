# 计划：把非 Go 语言的 opensnitch 相关包一起打入 repo.freelamp.com

> 目标：`opensnitch` 源码树实际产出 **3 个二进制包**，而当前管道只会产 1 个（且不完整）。
> 本文给出可行性核实结论 + 分阶段落地方案。

---

## 0. 结论速览

| 包 | 语言/架构 | 仓库现状 | 建议策略 | 复杂度 |
|---|---|---|---|---|
| `opensnitch`（daemon） | Go + cgo，any | 有 `1.8.0+LL`，**但只含 `/usr/bin/opensnitch`**；缺 service/config/man；**arm64 构建失败** | 修 recipe：补文件清单 + 二进制改名 `opensnitchd` + Depends + 修 arm64 cgo 交叉链接 | 中 |
| `python3-opensnitch-ui` | Python，**arch: all** | 无。Debian 官方只有 `1.6.9-3`（PyQt5），与 1.8.0 daemon 版本错配 | **重托管上游 release 的 `.deb`**（给 apt-repo 补"按资产名过滤的重托管"通道） | 低 |
| `opensnitch-ebpf-modules` | C / eBPF，amd64+arm64 | 无。**上游 release 不发这个 .deb** | 给 deb-builder 加 `build_script:` 机制，在 **Debian 容器内**用 Debian 内核头文件编译 | 中高 |

核心判断：**这三个包不是"再写两个 recipe"就能解决的**——管道缺两条能力（重托管通道、非 Go 构建通道），且一个源码出多包。

---

## 1. 现状核实（证据链）

### 1.1 现有打包入库链路

```
recipes/*.yaml
  └─ deb-builder/scripts/build-go-deb.sh   ← 单包：go build → /usr/bin/<包名> → dpkg-deb
       └─ dist/<pkg>_<ver>_<arch>.deb
            └─ .github/workflows/receive-trigger.yml  push 到 apt-repo/incoming/
                 └─ apt-repo/scripts/publish.sh  aptly: incoming → repo → snapshot → 发布到 7 个发行版
                      └─ gh-pages → repo.freelamp.com
```

- 发布目标（`apt-repo/conf/distros.txt`）：`bookworm trixie bullseye buster jammy noble resolute`
- 版本策略：`build-go-deb.sh` 生成 `${upstream_version}+LL`；`check-updates.sh` 每天扫 `releases/latest`，有新版就 bump recipe 并逐包触发构建。
- `build-go-deb.sh` 已支持 `language: rust`（2 个 recipe）、`cgo: true`（3 个）、`pre_build:`（3 个）。
- recipe 已知顶层字段仅：`repo/package/summary/description/homepage/section/version_tag/latest_tag/commit_hash/upstream_version/ldflags/target_arches/maintainer/depends/disabled/build_path/pre_build/cgo/language/build_env/go_get`。

### 1.2 仓库里 opensnitch 的实况（实测）

```
$ apt-cache policy opensnitch
  候选：1.8.0+LL   ← repo.freelamp.com trixie/main amd64
  已安装：1.6.9-3   ← Debian 官方
$ apt-cache policy python3-opensnitch-ui
  候选：1.6.9-3     ← 只有 Debian 官方，freelamp 无
```

`https://repo.freelamp.com/dists/trixie/main/binary-amd64/Packages` 中：

```
Package: opensnitch
Version: 1.8.0+LL
Filename: pool/main/o/opensnitch/opensnitch_1.8.0+LL_amd64.deb
```

下载该 deb 检查内容 —— **只有 1 个文件**：

```
./usr/bin/opensnitch        (17,645,952 bytes)
```

对比 Debian 官方 `opensnitch 1.6.9-3` 的内容：

```
/etc/init.d/opensnitch
/etc/logrotate.d/opensnitch
/etc/opensnitchd/default-config.json
/etc/opensnitchd/system-fw.json
/usr/bin/opensnitchd              ← 注意是 opensnitchd
/usr/lib/systemd/system/opensnitch.service
/usr/share/man/man1/opensnitchd.1.gz
```

> ⚠️ **结论：仓库里的 `opensnitch` 目前是"不可用"状态** —— 没有 systemd unit、没有 `/etc/opensnitchd/` 配置、二进制名与 service 内的 `ExecStart=/usr/bin/opensnitchd` 不一致、`Depends` 为空（缺 `libnetfilter-queue1`/`libnfnetlink0`）。
> 仓库另有 `arch: all` 索引缺失问题与 arm64 缺失问题，见下。

### 1.3 arm64 缺失（已定位原因）

`apt-repo` 的提交历史里，opensnitch 只推送过 1 个文件：

```
$ gh api repos/LeisureLinux/apt-repo/commits/<sha> --jq '.files[].filename'
incoming/opensnitch_1.8.0+LL_amd64.deb      ← 没有 arm64
```

原因：recipe 声明了 `cgo: true`，`build-go-deb.sh` 在 arm64 时设置 `CC=aarch64-linux-gnu-gcc`，但 CI（`receive-trigger.yml`）只装了宿主的 `libnetfilter-queue-dev`（amd64），链接阶段找不到 arm64 的 `libnetfilter_queue.so` → arm64 链接失败，脚本"单架构容错"逻辑静默跳过（`Partial build`）。
同类 cgo 包（`mender-client`、`stenographer`）会踩同一个坑。

### 1.4 上游 release 资产（evilsocket/opensnitch v1.8.0）

```
opensnitch_1.8.0-1_amd64.deb            4,752,284
opensnitch_1.8.0-1_arm64.deb            4,211,164
opensnitch_1.8.0-1_armhf.deb            4,270,620
opensnitch_1.8.0-1_i386.deb             4,353,228
python3-opensnitch-ui_1.8.0-1_all.deb     476,240   ← 我们需要的就是它
opensnitch-1.8.0-1.*.rpm
packages-builds-and-signatures.tar.gz
```

- ✅ 上游**提供** `python3-opensnitch-ui` 的 deb（arch: all）
- ❌ 上游**不提供** `opensnitch-ebpf-modules` 的 deb（ebpf 只作为 CI artifact，不打进 release）

### 1.5 上游源码树的打包结构

```
opensnitch/
├── daemon/                     → opensnitch (Go, cgo, libnetfilter_queue)
├── ui/                         → python3-opensnitch-ui (Python, setup.py, arch:all)
├── ebpf_prog/                  → opensnitch-ebpf-modules (C → clang → .o)
├── proto/                      → gRPC proto（daemon/ui 共用，已由 recipe 的 pre_build 生成）
└── utils/packaging/{daemon,ui}/{deb,rpm}/debian/   ← 上游自带的 dh 打包目录
```

Debian 官方 `opensnitch 1.6.9-3` 用**一个源码包出三个二进制包**（`debian/rules` 里 `dh $@ --buildsystem=golang --with=golang,python3`，并在 `override_dh_auto_install` 里分别落 `opensnitch` / `python3-opensnitch-ui` / `opensnitch-ebpf-modules`）。

`debian/control` 关键约束：

```
Package: opensnitch          Architecture: any
  Depends: libnetfilter-queue1, libc6, libnfnetlink0
  Recommends: python3-opensnitch-ui, opensnitch-ebpf-modules [amd64 arm64 riscv64 s390x loong64 ppc64]

Package: python3-opensnitch-ui   Architecture: all
  Depends: libqt5sql5-sqlite, python3-grpcio, python3-notify2, python3-packaging,
           python3-pyinotify, python3-pyqt5, python3-pyqt5.qtsql, python3-slugify,
           python3:any, xdg-user-dirs, gtk-update-icon-cache
  Recommends: python3-pyasn     Suggests: opensnitch

Package: opensnitch-ebpf-modules  Architecture: amd64 arm64 riscv64 s390x loong64 ppc64
  Suggests: opensnitch
```

`debian/rules` 中 ebpf 的架构白名单：

```make
ifeq ($(DEB_BUILD_ARCH),amd64)  → WITH_EBPF := true
else ifeq (...,arm64)           → true
else ifeq (...,riscv64|s390x|loong64|ppc64) → true
else                            → false      # i386 / armhf 不构建
```

### 1.6 ⚠️ PyQt5 → PyQt6 的坑（决定 UI 能否在旧发行版安装）

上游 **1.8.0 的 UI 已经迁移到 PyQt6**（对比：Debian 官方 1.6.9-3 还是 PyQt5）。实测上游 `python3-opensnitch-ui_1.8.0-1_all.deb` 的元数据：

```
Depends: netbase, pyqt6-dev-tools, libqt6sql6, libqt6sql6-sqlite, python3:any,
         python3-six, python3-pyqt6, python3-pyqt6.qtsvg, python3-pyinotify,
         python3-grpcio, python3-protobuf, python3-packaging, python3-slugify,
         python3-notify2, xdg-user-dirs, gtk-update-icon-cache
```

`python3-pyqt6` 在各发行版的可用性（实测拉取各 dists 的 Packages 索引）：

| 发行版 | `python3-pyqt6` | UI 1.8.0 是否可装 |
|---|---|---|
| Debian bookworm | ✅ | ✅ |
| Debian trixie | ✅ 6.9.0-2 | ✅ |
| Debian bullseye | ❌ | ❌ |
| Debian buster | ❌ | ❌ |
| Ubuntu jammy | ❌ | ❌ |
| Ubuntu noble | ✅ (universe) | ✅ |
| resolute | 待查 | 待查 |

⇒ **UI 包只对 bookworm / trixie / noble 有效**，而 `publish.sh` 会把同一份 `.deb` 发布到全部 7 个发行版（见第 5 节风险）。

### 1.7 eBPF 模块的构建硬约束

`ebpf_prog/Makefile`：

```make
KERNEL_VER     ?= $(shell find /lib/modules/* ... -name build -o -name source | sort | tail -1 | cut -d/ -f4)
KERNEL_DIR     ?= ... /lib/modules/$(KERNEL_VER)/...
KERNEL_HEADERS ?= /usr/src/linux-headers-$(KERNEL_VER)/
CC              = clang
%.bc: %.c  → $(CC) $(CFLAGS) -c $<          # -emit-llvm，-I$(KERNEL_HEADERS)/...
%.o:  %.bc → $(LLC) -march=bpf -mcpu=generic -filetype=obj -o $@ $<
```

- 依赖 `clang` + `llc`(llvm) + `llvm-strip` + **内核头文件**（`/lib/modules/<ver>/source` 或 `/usr/src/linux-headers-<ver>/`）
- **不是 CO-RE**（没有 `vmlinux.h` / BTF 重定位）→ 结构体偏移在编译期固化 → **必须用目标内核对应的头文件编译**
- 上游自带 `utils/packaging/build_modules.sh` 是"下载完整 kernel 源码再编"，太重；Debian 走 `linux-headers-<arch>`（并有补丁 1000 改成"取已安装的最新头文件"）
- `KERNEL_ARCH ?= $(shell uname -m)`，且 `-fcf-protection=full`(x86_64) / `-mbranch-protection=standard`(aarch64) 是按**构建机**架构选的 → **arm64 的 .o 需要在 arm64 环境里编**
- 产物安装位置：`/usr/lib/opensnitchd/ebpf/opensnitch{,-dns,-procs}.o`
- daemon 默认配置 `"ProcMonitorMethod": "ebpf"`（Debian 与上游默认均如此）→ **不装该包会导致进程监控退化**

### 1.8 ✅ `arch: all` 包能否被 apt 识别（已本地实测）

担心点：freelamp 仓库没有 `binary-all` 索引（`…/dists/trixie/main/binary-all/Packages` → 404），Release 里 `Architectures: amd64 arm64 armhf loong64 riscv64` 也不含 `all`。

- 读 aptly 源码 `deb/publish.go`：aptly 遍历 `p.Architectures`，对每个具体架构调用 `pkg.MatchesArchitecture(arch)`，**`arch:all` 的包会写进每一个 `binary-<arch>/Packages`**，不生成 `binary-all`。
- 本地构造最小仓库实测（只有 `binary-amd64/Packages`，内含一条 `Architecture: all`）：

```
$ apt-cache -o Dir=/tmp/alltest/root ... policy python3-opensnitch-ui
python3-opensnitch-ui:
  候选： 1.8.0-1
  版本列表：
     1.8.0-1 500
        500 file:/tmp/alltest/repo test/main amd64 Packages     ← ✅ 被识别
```

⇒ **不需要给仓库加 `binary-all`**，把 `arch: all` 的 `.deb` 丢进 `incoming/` 即可，aptly 会自动广播到各架构索引。

---

## 2. 管道缺口（必须补的能力）

| # | 缺口 | 影响 | 补法 |
|---|---|---|---|
| A | 只有"源码编译 Go"一条路；README 里写的 `⚠️ Official .deb exists (re-host same asset)` 分类**从未实现** | python3-opensnitch-ui 无法入库 | 给 apt-repo 补"按资产名过滤的重托管"通道 |
| B | recipe 模型是 **1 recipe = 1 包 = 1 个二进制**，无法给包补 systemd unit / conffile | opensnitch 主包不可用 | 给 build-go-deb.sh 加 `deb_files:`（额外文件注入）与 `deb_script:`（整包自定义） |
| C | 非 Go 构建（Python / eBPF）无通道 | ebpf-modules 无法入库 | 给 build-go-deb.sh 加 `build_script:` 逃生舱 |
| D | 发布无"发行版维度"过滤，全部 7 个发行版同发 | pyqt6 依赖在 bullseye/jammy 上不可满足 | （可选）recipe 加 `publish_distros:`，透传到 publish.sh |

---

## 3. 推荐方案

### Phase 2 — 先修 `opensnitch` 主包（必修，与另两包同源）

**为什么先做**：现在仓库里的 `opensnitch` 是坏的，无论加不加另两个包都得修；而且三个包共享同一次源码构建，先统一打包方式最省事。

**改动 1：`build-go-deb.sh` 支持额外文件注入**

新增 recipe 字段（最小侵入）：

```yaml
# 从源码树把文件铺进 DEB_ROOT（源路径 目标路径，目标用相对 DEB_ROOT 的路径）
deb_files:
  - "daemon/default-config.json        etc/opensnitchd/"
  - "daemon/system-fw.json             etc/opensnitchd/"
  - "packaging/opensnitch.service      lib/systemd/system/opensnitch.service"
  - "packaging/opensnitch.init         etc/init.d/opensnitch"
  - "packaging/opensnitch.logrotate    etc/logrotate.d/opensnitch"
# 权限修正（可选）
deb_modes:
  - "0755 etc/init.d/opensnitch"

# conffile 声明（生成 DEBIAN/conffiles）
conffiles:
  - /etc/opensnitchd/default-config.json
  - /etc/opensnitchd/system-fw.json

# 二进制安装名（默认 = 包名，opensnitch 需要改成 opensnitchd）
binary_name: opensnitchd
```

> 这三个文件（service / init / logrotate）**上游 release 的 deb 里有，但上游 git 源码树里没有** —— 它们来自 Debian 打包（`utils/packaging/daemon/deb/debian/`）。所以要么把内容落到 `deb-builder/scripts/pkgs/opensnitch/` 下自维护（推荐，约 3KB），要么在 `pre_build` 里从 Debian salsa / GitHub 抓。推荐**自维护**，避免引入外部依赖。

**改动 2：recipe 修正**

```yaml
# recipes/opensnitch.yaml 追加/修改
binary_name: opensnitchd
depends:
  - libc6 (>= 2.34)
  - libnetfilter-queue1
  - libnfnetlink0
recommends:
  - python3-opensnitch-ui
  - opensnitch-ebpf-modules
deb_files: [...]
conffiles: [...]
```

**改动 3：修 arm64 cgo 交叉链接**

`receive-trigger.yml` / `build.yml` 里，cgo 包需要安装 arm64 版库：

```bash
# 现有
sudo apt-get install -y gcc-aarch64-linux-gnu libnetfilter-queue-dev ...
# 追加（仅 cgo 包需要）
sudo dpkg --add-architecture arm64
# 需要给 arm64 单独加 ports 源后：
sudo apt-get install -y libnetfilter-queue1:arm64 libnfnetlink0:arm64 libnetfilter-queue-dev:arm64
```

更干净的做法：只在 `build-go-deb.sh` 的 cgo 分支里，对非宿主架构显式传 `CGO_LDFLAGS`/`PKG_CONFIG_PATH` 指向 `/usr/lib/aarch64-linux-gnu/pkgconfig`，并在 CI 用 `:arm64` multiarch 装依赖。**这是一个通用修复，能同时救 `mender-client`、`stenographer`。**

**验收**：`apt install ./opensnitch_1.8.0+LL_amd64.deb` → `systemctl enable --now opensnitch` 能起；`dpkg -L` 有 service + config；arm64 产物出现在 `dist/`。

---

### Phase 3 — `python3-opensnitch-ui`：**重托管上游 .deb**（推荐）

**理由**：
1. `Architecture: all` 的纯 Python 包，我们"编译"不出任何东西 —— 重托管就是正确工程选择；
2. 上游 release 的 deb 已在真实环境验证过，零构建风险；
3. 与上游 commit 严格同源，避免我们自建时 proto 版本错配；
4. 这正好补上 README 里承诺但未实现的 `⚠️ 重托管` 分类。

**改动：apt-repo 侧，`conf/sources.txt` 支持"资产名过滤"**

```
# 现状：拉 release 里**全部** .deb
LeisureLinux/ghdeb

# 新增语法：owner/repo 后跟一个资产名 glob
evilsocket/opensnitch:python3-opensnitch-ui_*_all.deb
```

`scripts/fetch-sources.sh` 里 jq 过滤加一层（约 5 行）：

```bash
# spec 形如 owner/repo                 → 取全部 .deb
# spec 形如 owner/repo:glob            → 只取匹配 glob 的 .deb
if [[ "$spec" == *":"* ]]; then
  repo_spec="${spec%%:*}"; asset_glob="${spec#*:}"
else
  repo_spec="$spec"; asset_glob="*.deb"
fi
...
| jq -r --arg g "$asset_glob" \
    '.assets[] | select(.name | endswith(".deb")) | select(.name | test($g | gsub("\\*"; ".*") | gsub("\\."; "\\."))) | .browser_download_url'
```

> 为什么不直接把 `evilsocket/opensnitch` 整行加进 `sources.txt`：那会把上游的 `opensnitch_1.8.0-1_{amd64,arm64,armhf,i386}.deb` 一起拉进来，与自建的 `opensnitch_1.8.0+LL` 同名不同版本（`publish.sh` 会按版本去重保留 `+LL`，不出错但会把 i386/armhf 也带进仓库），噪音大且容易误判。

**备选（不推荐）**：从源码 `ui/` 目录构建 —— 需要 `pyrcc6/pyqt6-dev-tools`、`python3-grpc-tools`、`gettext`、`dh-python`，且 1.8.0 源码已 PyQt6 化，想降到 PyQt5 兼容 bullseye/jammy 要打大补丁。只有在"必须统一 `+LL` 版本后缀"或"必须支持旧发行版"时才考虑。

**版本号说明**：重托管后 UI 版本是上游的 `1.8.0-1`，与 daemon 的 `1.8.0+LL` 字符串不同、但上游版本一致，可以接受。

---

### Phase 4 — `opensnitch-ebpf-modules`：新增 `build_script:` 逃生舱

**改动 1：`build-go-deb.sh` 顶部加一个分支**

```bash
# 自定义构建逃生舱：recipe 声明 build_script 时，交给脚本自行产出 dist/*.deb
BUILD_SCRIPT=$(grep '^build_script:' "$RECIPE" 2>/dev/null | head -1 | sed 's/^build_script:[[:space:]]*//' | tr -d '"' || true)
if [[ -n "$BUILD_SCRIPT" ]]; then
  export PKG_NAME VERSION="$VERSION" FINAL_VERSION="$FINAL_VERSION" \
         ARCHS_CSV="$ARCHS_CSV" RECIPE OUTPUT_DIR="$(pwd)/dist" \
         REPO_LINE="$repo_line" UPGRADE_VERSION="$UPGRADE_VERSION"
  exec bash "$BUILD_SCRIPT"
fi
```

好处：200 个既有 Go recipe **零影响**；非 Go 包各写一个小脚本；`build-one.sh` 的禁用/缺失跳过、CI 的批量推送、apt-repo 的去重全部自动复用。

**改动 2：新增 `scripts/pkgs/opensnitch-ebpf-modules.sh`（核心逻辑）**

```bash
# 在 Debian trixie 容器内编译，保证内核头文件 ABI 与 Debian 用户一致
docker run --rm -v "$PWD:/src" -w /src debian:trixie bash -c '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
      build-essential clang llvm libelf-dev make \
      linux-headers-amd64        # 或 linux-headers-arm64（arm64 环境）
  cd <cloned-src>/ebpf_prog
  make
  # 产出 opensnitch.o opensnitch-dns.o opensnitch-procs.o
'
# 组装 deb：Architecture: amd64, section net, Suggests: opensnitch
#   /usr/lib/opensnitchd/ebpf/{opensnitch,opensnitch-dns,opensnitch-procs}.o
```

**改动 3：`recipes/opensnitch-ebpf-modules.yaml`**

```yaml
repo: evilsocket/opensnitch
package: opensnitch-ebpf-modules
language: c
build_script: scripts/pkgs/opensnitch-ebpf-modules.sh
target_arches: [amd64]        # arm64 见第 5 节决策
section: net
depends: []
suggests: opensnitch
```

**几个必须注意的点**：
- eBPF `.o` 不是 CO-RE，**必须用目标内核头文件**编译 → 不能在 ubuntu-latest runner 上用 azure 内核头文件直接编；
- 支持的架构白名单：`amd64 arm64 riscv64 s390x loong64 ppc64`（**没有 i386/armhf**）；
- 产物路径固定为 `/usr/lib/opensnitchd/ebpf/`（daemon 从中加载）；
- 用 `-mcpu=generic`，所以同一 arch 的 `.o` 可跨发行版用（Debian 官方就是这么做的）。

---

### Phase 5（可选）— 按发行版过滤发布

给 recipe 加 `publish_distros:`，`receive-trigger.yml` 的 dispatch payload 带上它，`publish.sh` 按发行版过滤。用于让 `python3-opensnitch-ui`（PyQt6）只进 `bookworm/trixie/noble`。

---

## 4. 落地顺序

| 阶段 | 内容 | 依赖 | 风险 |
|---|---|---|---|
| P1 | 管道扩展：`build_script:` + `deb_files:`/`binary_name:`/`conffiles:` + apt-repo 资产名过滤 | 无 | 低（对既有 recipe 无行为变化） |
| P2 | 修 `opensnitch` 主包（service/config/改名/Depends + arm64 cgo） | P1 | 低 |
| P3 | `python3-opensnitch-ui` 重托管入库 | P1（apt-repo 侧） | 极低 |
| P4 | `opensnitch-ebpf-modules` 容器内构建入库 | P1 | 中（内核头文件/arm64） |
| P5 | 按发行版过滤发布（可选） | P3 | 低 |

P1/P3 可并行；P2 与 P4 建议串行（都要动 opensnitch 相关的 arches 逻辑）。

---

## 5. 风险与待决策

### 决策 1：UI 在旧发行版（bullseye / buster / jammy）怎么办？
- 方案 a（省事）：照发，接受"装了也解不出依赖"。因为我们的 `opensnitch` 不声明 `Recommends`，**不会阻塞 daemon 安装**；用户手动 `apt install python3-opensnitch-ui` 会拿到 unmet dependencies 报错。需在 README 注明。
- 方案 b（干净）：做 Phase 5 的按发行版过滤，UI 只进 bookworm/trixie/noble。
- 方案 c：为旧发行版另编一份 PyQt5 版 UI（要维护补丁分支，成本高）。

**建议：先 a，观察后补 b。**

### 决策 2：arm64 的 eBPF 模块怎么编？
- 方案 a：先用 GitHub 的 **arm64 原生 runner**（`ubuntu-24.04-arm`）做 matrix，`docker run --platform linux/arm64 debian:trixie` 或直接跑；
- 方案 b：amd64 上用 `qemu-user-static` + `linux-headers-arm64` 交叉编（配置麻烦，`KERNEL_ARCH` 取 `uname -m` 会取错，需要 `make KERNEL_ARCH=aarch64`）；
- 方案 c：先只发 amd64 的 ebpf 包，arm64 用 Debian 官方的（版本 1.6.9，可能不匹配）。

**建议：先 c 保证 amd64 可用，再上 a。**

### 决策 3：版本后缀是否统一？
重托管 UI 是 `1.8.0-1`，自建是 `1.8.0+LL`。若要求严格一致 → 只能走"从源码构建 UI"。
**建议：不统一，接受上游版本字符串。**

### 其他风险
- **版本联动**：三个 recipe 共享同一 `repo:` → `check-updates.sh` 会在同一轮把三个 recipe 都 bump 到同一 tag，天然一致。但 `python3-opensnitch-ui` 走重托管（apt-repo 的 `sources.txt` 拉 latest），**它的更新节奏独立于 recipe**，可能出现"daemon 已是 1.9.0、UI 还是 1.8.0"。缓解：daemon recipe 的 `latest_tag` 与重托管都跟 `releases/latest`，偏差窗口通常 < 1 天。
- **混版风险已存在**：现在仓库里 daemon 1.8.0 + Debian UI 1.6.9，UI 的 gRPC proto 与 daemon 可能不兼容。这正是必须把 UI 补进来的根因。
- **`aptly` 单池共享**：`publish.sh` 每次用 `incoming/` 全量重建仓库（`incoming/*.deb` 绝不能清理）。新增的两个包会进入这个全量集合，需确认 `incoming/` 的体积增长可接受（UI 0.5MB + ebpf ≈ 30KB，可忽略）。

---

## 6. 验收清单

```bash
# 1) 包存在且三件套齐全
for p in opensnitch python3-opensnitch-ui opensnitch-ebpf-modules; do
  apt-cache policy "$p"; done

# 2) opensnitch 内容完整（service + config + 正确的二进制名）
apt-get download opensnitch && dpkg-deb -c opensnitch_*.deb | grep -E 'opensnitchd|systemd|opensnitchd/'
dpkg-deb -f opensnitch_*.deb Depends Recommends

# 3) arch:all 的 UI 在 amd64/arm64 索引中都能看到
curl -s https://repo.freelamp.com/dists/trixie/main/binary-amd64/Packages | grep -A3 'Package: python3-opensnitch-ui'
curl -s https://repo.freelamp.com/dists/trixie/main/binary-arm64/Packages | grep -A3 'Package: python3-opensnitch-ui'

# 4) ebpf 模块落位正确
dpkg-deb -c opensnitch-ebpf-modules_*.deb | grep '/usr/lib/opensnitchd/ebpf/'

# 5) 端到端：干净 trixie 容器里能装能起
docker run --rm -it debian:trixie bash -c '
  echo "deb [trusted=yes] https://repo.freelamp.com trixie main" >/etc/apt/sources.list.d/fl.list
  apt-get update && apt-get install -y opensnitch python3-opensnitch-ui opensnitch-ebpf-modules
  systemctl is-enabled opensnitch || true
  opensnitchd --version; opensnitch-ui --help >/dev/null && echo UI-OK'

# 6) arm64 产物已入库
curl -s https://repo.freelamp.com/dists/trixie/main/binary-arm64/Packages | grep -c '^Package: opensnitch$'
```

---

## 附录 A：opensnitch 主包需要补的文件清单（对齐上游 1.8.0 deb）

| 目标路径 | 来源 | 说明 |
|---|---|---|
| `/usr/bin/opensnitchd` | 构建产物改名 | 上游与 Debian 均用此名，service 内写死 |
| `/lib/systemd/system/opensnitch.service` | 自维护（内容见 Debian debian/opensnitch.service） | `ExecStart=/usr/bin/opensnitchd -rules-path /etc/opensnitchd/rules` |
| `/etc/init.d/opensnitch` | 自维护（上游 release deb 内，1.9KB） | sysvinit 兼容 |
| `/etc/logrotate.d/opensnitch` | 自维护（235B） | 日志轮转 |
| `/etc/opensnitchd/default-config.json` | `daemon/default-config.json` | conffile |
| `/etc/opensnitchd/network_aliases.json` | 上游 release deb 内（221B） | 1.8.0 新增 |
| `/etc/opensnitchd/system-fw.json` | `daemon/system-fw.json` | conffile |
| `/etc/opensnitchd/tasks/tasks.json` | 上游 release deb 内（20B） | 1.8.0 新增 |
| `/etc/opensnitchd/rules/000-allow-localhost{,6}.json` | 上游 release deb 内 | 默认放行本机 |
| `/usr/share/man/man1/opensnitchd.1.gz` | Debian `debian/man/opensnitchd.1` | 可选 |

## 附录 B：本文所有结论的核实命令

```bash
apt-cache rdepends opensnitch
apt-cache show opensnitch python3-opensnitch-ui opensnitch-ebpf-modules
dpkg -L opensnitch-ebpf-modules
curl -s https://api.github.com/repos/evilsocket/opensnitch/releases | jq -r '.[0]|.assets[].name'
curl -s https://repo.freelamp.com/dists/trixie/main/binary-amd64/Packages | grep -A8 '^Package: opensnitch$'
gh api repos/LeisureLinux/apt-repo/commits/<sha> --jq '.files[].filename'
curl -sL http://deb.debian.org/debian/pool/main/o/opensnitch/opensnitch_1.6.9-3.debian.tar.xz | tar -xJ
```

*文档生成时间：2026-09-12*

---

# 7. 实施记录（as-built）

*实施时间：2026-09-12 ｜ 状态：三包全部本地构建通过*

## 7.1 与计划的偏差

| 项 | 计划 | 实际 | 原因 |
|---|---|---|---|
| UI 包 | Phase 3「重托管上游 .deb」 | **从源码自建** | 上游 deb 是 `1.8.0-1`，与自建 daemon 的 `1.8.0+LL` 不一致；daemon↔UI 有版本校验，不统一会告警 |
| eBPF | Phase 4「trixie 容器内编译」 | **当前 host 直接编译** | 按大侠决策：不用容器；产物同样只落进包根，`dpkg-deb --root-owner-group` 打包，不写宿主 `/usr` `/etc` `/root` |
| arm64 | 计划内 | **暂不产出**，recipe 只声明 amd64 | cgo 交叉链接缺 arm64 版 netfilter 开发包（实测 `找不到 -lnetfilter_queue`），CI 同样缺 |
| loong64/riscv64 | 声明保留 | 保持注释 | 未变 |

## 7.2 新增/修改的文件

**recipes/**
- `recipes/opensnitch.yaml`（重写）：`binary_name: opensnitchd`、`build_path: daemon`、`depends/recommends`、`deb_files`（6 个配置）、`extra_root`、`control_dir`、`cgo: true`、`pre_build`（生成 gRPC 代码）
- `recipes/python3-opensnitch-ui.yaml`（新）：`build_script`，arch:all，Depends 对齐上游 deb
- `recipes/opensnitch-ebpf-modules.yaml`（新）：`build_script`，amd64，无 Depends，`suggests: opensnitch`

**scripts/pkgs/**（新增，非 Go 包的构建脚本）
- `common.sh`：`clone_upstream` / `deb_write_control` / `deb_apply_extra` / `deb_finalize` / `bpf_sections` / `tmpabs`
- `python3-opensnitch-ui.sh`：铺 python 包体 + data_files + 编译 25 个语种 `.qm`
- `opensnitch-ebpf-modules.sh`：探测内核头文件、编译 eBPF、校验程序段
- `tools/llc-shim.sh`、`tools/cc-nog.sh`：`llc` / `-g` 的替代与裁剪
- `opensnitch/root/…`：systemd unit、init.d、logrotate（上游源码树里没有，只存在于打包目录）
- `opensnitch/debian/…`：conffiles、postinst、prerm、postrm

**scripts/build-go-deb.sh**（共享管线，改动均为「让非 Go 包和本机构建能跑通」）
1. `TMPBASE` 立刻转绝对路径 + `export TMPDIR="$TMPBASE"` + 临时区空间自检
2. clone 后校验工作树非空（偶发"克隆成功但检出失败"）
3. `export GO111MODULE=on`（宿主 `go env` 里是 off）+ `GOPROXY` 默认 `https://goproxy.cn,direct`
4. `extra_root` / `control_dir` / `build_script` 统一相对仓库根转绝对路径
5. `deb_files` 行解析：先去空白再去 `-`（YAML 列表项有缩进）
6. `binary_name` / `recommends` / `suggests` / `deb_files` / `extra_root` / `control_dir` / `build_script` 字段支持

**scripts/generate-recipes.sh**
- 已存在的 recipe 不再被 `cat >` 覆盖（需 `FORCE=1` 才覆盖）
- 否则下次生成器会把 `opensnitch.yaml` 冲成基础模板，手写的 depends/deb_files/extra_root 全丢

## 7.3 实测验证

```
dist/opensnitch_1.8.0+LL_amd64.deb                  5 131 444 B
dist/python3-opensnitch-ui_1.8.0+LL_all.deb           427 236 B
dist/opensnitch-ebpf-modules_1.8.0+LL_amd64.deb         6 752 B
三个 build-one.sh 退出码均为 0
```

| 检查 | 结果 |
|---|---|
| daemon 的 8 个 conffile 路径 | 与上游 deb **完全一致** |
| daemon 的 6 个配置/systemd 文件 | 与上游 deb **逐字节相同**（`cmp`） |
| daemon 的 NEEDED | `libnetfilter_queue.so.1` / `libnfnetlink.so.0` / `libc.so.6` → 与 Depends **一一对应** |
| UI 文件清单 | 与上游 deb 对比：除 `resources_rc.py`、`egg-info/*`、`share/doc/*` 外无差异（`resources_rc.py` 上游也无人 import） |
| UI 翻译 | 25 个语种 `.qm`，zh_TW 520 条；**zh_Hans 上游只有 2 条完成翻译**，不是构建问题 |
| eBPF 程序段 | `opensnitch.o` 10 个 kprobe/kretprobe、`opensnitch-procs.o` 5 个 tracepoint、`opensnitch-dns.o` 3 个 uprobe/uretprobe |
| eBPF 编译内核 | Debian `6.12.48+deb13-amd64`（优先发行版头文件，非 xanmod） |

## 7.4 未决 / 后续可做

1. **arm64**：两条路（recipe 注释里也写了）——A. GitHub `ubuntu-24.04-arm` 原生 runner，一个 matrix 同时解决 daemon / UI / eBPF；B. runner 上 `dpkg --add-architecture arm64` + ports 源装 arm64 开发包做交叉编译。方案 A 更干净。
2. **依赖漂移**：`pre_build` 里 `go get …@latest` 把 grpc 1.32→1.83、protobuf 1.26→1.36（上游 `daemon/go.mod` 的钉版）。原因：`daemon/ui/protocol/` 只有 `.gitkeep`，gRPC 代码必须现场生成，而新 `protoc-gen-go` 生成的代码要求更新的 runtime。如需完全贴合上游，可把 `protoc-gen-go` 降到与 protobuf v1.26 同期的版本再验证。
3. **`/usr/share/doc/`**：三包都没有 `copyright` / `changelog.Debian.gz`（本仓库 200+ 个包现状如此，保持一致）。要做就整仓库一起做。
4. **`DEBIAN/md5sums`**：上游 deb 有（`dpkg --verify` 用），本仓库管线不生成。要加就在 `deb_finalize` 和 Go 路径里各补一段。

---

# 8. 第二批次实施记录（arm64 / per-suite / 简体中文）

*实施时间：2026-09-12 ｜ 状态：本地全部验证通过*

## 8.1 本批次的四项决策（LeisureLinux 大侠指定）

| # | 决策 | 落地方式 |
|---|---|---|
| 1 | **arm64 用方案 A**（原生 runner） | build.yml / receive-trigger.yml 改为按架构 matrix，arm64 跑 `ubuntu-24.04-arm` |
| 2 | **依赖用新版**（不降级 gRPC/protobuf） | 保留 `pre_build` 里的 `go get …@latest`，不再尝试钉回 v1.26 |
| 3 | **per-suite 过滤，只发 trixie** | recipe 新增 `suites` → control 写 `XB-Suites` → apt-repo/publish.sh 按字段分流 |
| 4 | **补上 zh_Hans** | 上游该语种是空壳，补全 557 条译文并随构建替换 |

## 8.2 arm64：从交叉编译改为原生 runner

**为什么必须换**：daemon 是 cgo 包，交叉链接 arm64 需要 arm64 版的 `libnetfilter_queue` /
`libnfnetlink`。在本机（x86_64）实测：

```
/usr/lib/gcc-cross/aarch64-linux-gnu/14/.../ld: 找不到 -lnetfilter_queue: 没有那个文件或目录
/usr/lib/gcc-cross/aarch64-linux-gnu/14/.../ld: 找不到 -lnfnetlink: 没有那个文件或目录
```

这在 x64 runner 上同样成立（CI 只装了 amd64 的开发包）。本仓库是公开仓库，GitHub 的
`ubuntu-24.04-arm` runner 免费，于是直接原生构建，连 eBPF 那套"构建机架构 = 目标架构"
的约束也顺带满足了。

**workflow 结构变化**（两个文件同构）：

```
setup   ── 解析"构建哪些包" + 生成架构矩阵 JSON（jq）
   ↓
build   ── matrix: {amd64: ubuntu-latest, arm64: ubuntu-24.04-arm}
   │       每台 runner 只构建自己那一个架构，产物 upload-artifact
   ↓
publish ── download-artifact 合并 → 一次性推 apt-repo → 触发 publish
```

要点：
* 单包/批量/全量三种模式都走这套矩阵；`ARCHS_OVERRIDE` 从 `amd64,arm64` 变成单架构。
* `fail-fast: false`：一个架构失败不取消另一个，便于对比排查（但发布仍要求全部成功）。
* 发布只推一次（汇总 artifact 后统一 push），避免两路并发 push 同一仓库。
* 依赖安装里补了 `clang` 与**内核头文件**（eBPF 编译需要；失败不致命）。

**连带修掉的一个真问题**：`build_script` 分支原先排在 `target_arches` 交集过滤**之前**，
导致 arch:all 的包会在两个架构的 runner 上各产出一份**同名** .deb，artifact 合并时撞车。
现在过滤前置，且交集为空时 `exit 2`（= 干净跳过），于是：

```
ARCHS_OVERRIDE=arm64 build-one.sh python3-opensnitch-ui
⏭️  python3-opensnitch-ui: 请求的架构（arm64）不在 target_arches（amd64）内，跳过   → exit 2
```

这同时修好了 loong64/riscv64 之类"声明了但没启用"的架构请求 —— 以前会白跑一遍构建。

## 8.3 内核头文件探测的兜底

原实现只从 `/lib/modules/*` 枚举版本，漏掉了"装了头文件但没装内核"的情形
（CI 上 `apt install linux-headers-generic` 就是这样：`/usr/src/linux-headers-<v>` 存在，
`/lib/modules/<v>` 不存在）。已改为先枚举 `/lib/modules`（官方 `source` 软链优先），
再补扫 `/usr/src/linux-headers-*`（跳过 `-common` 辅助目录），去重后按优先级输出。
本机回归：仍优先选中 `/lib/modules/6.12.48+deb13-amd64/source`，行为不变。

## 8.4 per-suite 发布：两端实现

**构建端（deb-builder）**

* recipe 新增 `suites:` 字段（列表，为空 = 全发行版）。
* `build-go-deb.sh` 与 `scripts/pkgs/common.sh` 都把它写成 control 的 `XB-Suites: <逗号分隔>`。
  用 `XB-` 前缀是 Debian 政策给自定义字段留的位置，dpkg / aptly 都会原样保留
  （实测 aptly 里显示为 `Xb-Suites`）。
* 让信息跟着 `.deb` 走，而不是在 apt-repo 里维护一份名单 —— 只有 recipe 知道这个包
  的依赖/内核约束，apt-repo 不该反过来依赖 deb-builder 的内部结构。

**发布端（apt-repo/scripts/publish.sh）**

```
incoming/*.deb
   ├─ 无 XB-Suites ──→ aptly repo `freelamp`              ──→ snapshot A
   └─ XB-Suites: X ──→ aptly repo `freelamp-s-X`          ──→ snapshot B
                                   ↓
      每个发行版：A （+ 所有把该发行版列进 XB-Suites 的快照） → snapshot merge → publish
```

* 只有需要合并时才 `snapshot merge`；只有一个来源就直接发布，省一次操作。
* 入库前会先把 incoming 里出现过的**所有包名**从每个 repo 移除：既清旧版本，也清掉
  "包换了分组"时留在旧 repo 里的残影（否则 merge 会因同名包冲突而失败）。
* 全量包的行为完全不变（仍进 `freelamp`，仍发全部发行版）。

## 8.5 简体中文：上游是空壳，且有西班牙语污染

补全 zh_Hans 时发现的实情（都在上游 v1.8.0 的 `ui/i18n/locales/zh_Hans/` 里）：

* 771 条 message，**只有 2 条**真正完成翻译；
* 另有 8 条"已完成"的其实是**西班牙语**（`Habilitar`、`IP Destino`、`Protocolo`、
  `30 segundos`、`1m → 5 minutos {1m?}`……），显然是从 es.ts 误粘过来的 ——
  这些会被 lrelease 编进 `.qm`，界面上一半西语；
* 122 条 obsolete 条目里也全是西语残渣。

处理方式：以补全为中文替代上游文件。译文覆盖 557 条（556 finished），
仅数字 / nftables 关键字 / 路径（`30s`、`DROP`、`/dev/stdout`、`md5` 等 92 条）保留，
由 Qt 回退到英文源串 —— 与其它语种的时间缩写风格也一致。

**结果对比**：

| | 上游 | 本仓库 |
|---|---|---|
| finished 译文 | 2 | **556** |
| 未翻译被忽略 | 638 | **92** |
| `.qm` 体积 | 933 B | **50 278 B**（zh_TW 为 54 044 B） |

归档位置 `scripts/pkgs/opensnitch/i18n/opensnitch-zh_Hans.ts`，
构建时由 `python3-opensnitch-ui.sh` 覆盖源码树里的同名文件再统一 lrelease；
若上游将来新增字符串（message 条数变多），构建会打印告警提示同步。

## 8.6 本批次验证证据

| 检查 | 结果 |
|---|---|
| 三包 amd64 构建 | exit=0，均带 `XB-Suites: trixie` |
| 架构交集（arm64 请求 arch:all 包） | exit 2 干净跳过 |
| 架构交集（loong64 请求仅 amd64+arm64 的包） | exit 2 干净跳过 |
| arm64 请求 eBPF（非原生机器） | exit 2 如实跳过，不产假包 |
| arm64 请求 daemon（本机） | 进入编译后因缺 arm64 netfilter 库失败 —— 证明声明已生效，CI 上装好依赖即可 |
| `snapshot merge` 语义 | 合并快照含两方包；`XB-Suites` 字段被 aptly 保留 |
| **端到端发布**（隔离环境真跑 publish.sh） | trixie 索引含 4 个包（3 个 opensnitch + 1 个普通包）；bookworm/noble 只含普通包 |
| zh_Hans `.qm` | 50 278 B，557 条译文（556 finished） |

端到端发布用的是 apt-repo 的隔离副本 + `-skip-signing`（绕过 GPG），分流逻辑本身是真跑的。

## 8.7 未决 / 注意

1. **arm64 首次真实构建尚未发生**：本机没有 arm64 环境，方案 A 的链路只能
   在 CI 上跑第一次 `workflow_dispatch` 时才能确认（重点看 eBPF 包能否在
   `ubuntu-24.04-arm` 上找到内核头文件）。
2. **`generate-index.sh` 的首页包列表取自 bookworm**（`dists/bookworm/.../Packages`）。
   只发 trixie 的 opensnitch 因此不会出现在站点首页总表里，但各发行版索引与
   `dists/<dist>/` 页面都正常。若希望出现在首页，需要把取数改成所有发行版的并集
   （并标注“仅 trixie”）。
3. **依赖漂移按大侠决策保留**（gRPC 1.32→1.83.2、protobuf 1.26→1.36.12），
   不再尝试回钉 —— 因为上游 `daemon/ui/protocol/` 只有 `.gitkeep`，gRPC 代码必须现场生成。
4. **构建机磁盘**：验证过程中该机根分区可用空间只剩 11 GiB（98%），
   大包构建可能因此失败，建议清理。
