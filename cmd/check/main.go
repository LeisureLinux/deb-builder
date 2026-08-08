// 检查器：对候选清单做三分类
//   - Debian 已覆盖（该 suite/arch 有官方二进制）→ 跳过
//   - 官方 release 有该架构 .deb → 可直接 re-host
//   - 缺口（两者都没有）→ 进入构建队列
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

type Candidate struct {
	Repo       string            `json:"repo"`
	Name       string            `json:"name"`
	Names      []string          `json:"names"`
	Homepage   string            `json:"homepage"`
	Section    string            `json:"section"`
	Summary    string            `json:"summary"`
	FoundIn    []string          `json:"found_in"`
	DebianVers map[string]string `json:"debian_versions,omitempty"`
}

type ReleaseInfo struct {
	Tag     string   `json:"tag_name"`
	DebArcs []string `json:"-"`
}

// 官方 .deb 资产文件名 → 我们关心的架构
var archTokens = []struct{ pat, arch string }{
	{"amd64", "amd64"}, {"x86_64", "amd64"},
	{"arm64", "arm64"}, {"aarch64", "arm64"},
	{"armhf", "armhf"}, {"armv7", "armhf"}, {"arm-7", "armhf"},
	{"loong64", "loong64"}, {"loongarch64", "loong64"},
	{"riscv64", "riscv64"}, {"i386", "i386"}, {"ppc64el", "ppc64el"}, {"s390x", "s390x"},
}

func main() {
	candFile := flag.String("candidates", "candidates.json", "扫描器输出")
	reportFile := flag.String("report", "report.md", "报告输出")
	gapsFile := flag.String("gaps", "gaps.json", "缺口清单输出")
	arches := flag.String("arches", "amd64,arm64,armhf,riscv64,loong64", "关心的架构（官方资产判定用）")
	flag.Parse()

	data, err := os.ReadFile(*candFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "❌ 读取候选:", err)
		os.Exit(1)
	}
	var cands []Candidate
	if err := json.Unmarshal(data, &cands); err != nil {
		fmt.Fprintln(os.Stderr, "❌ 解析候选:", err)
		os.Exit(1)
	}

	wantArches := strings.Split(*arches, ",")
	client := &http.Client{Timeout: 30 * time.Second}

	type result struct {
		c   Candidate
		rel ReleaseInfo
		err error
	}
	results := make([]result, 0, len(cands))
	for _, c := range cands {
		rel, err := fetchRelease(client, c.Repo)
		results = append(results, result{c, rel, err})
		time.Sleep(200 * time.Millisecond) // 温和限速
	}

	// 统计缺口
	var gaps []map[string]any
	var sb strings.Builder
	sb.WriteString("# Debian→GitHub 缺口检查报告\n\n")
	sb.WriteString(fmt.Sprintf("候选 %d 个 · 架构矩阵: %s\n\n", len(cands), strings.Join(wantArches, ", ")))
	sb.WriteString("| 包 | GitHub 仓库 | 上游最新 | 官方 .deb | 缺口(suite/arch) |\n")
	sb.WriteString("|---|---|---|---|---|\n")

	type gapCell struct{ repo, cell string }
	for _, r := range results {
		official := map[string]bool{}
		for _, a := range r.rel.DebArcs {
			official[a] = true
		}
		hasOfficial := len(r.rel.DebArcs) > 0
		var cellGaps []string
		for _, suite := range suitesFrom(r.c) {
			for _, a := range wantArches {
				loc := suite + "/" + a
				debian := containsStr(r.c.FoundIn, loc)
				if !debian && !official[a] {
					cellGaps = append(cellGaps, loc)
				}
			}
		}
		offStr := "—"
		if hasOfficial {
			offStr = strings.Join(r.rel.DebArcs, ",")
		}
		gapStr := "—"
		if len(cellGaps) > 0 {
			gapStr = strings.Join(cellGaps, ", ")
			gaps = append(gaps, map[string]any{
				"repo":                r.c.Repo,
				"name":                r.c.Name,
				"homepage":            r.c.Homepage,
				"latest":              r.rel.Tag,
				"official_deb_arches": r.rel.DebArcs,
				"gaps":                cellGaps,
			})
		}
		sb.WriteString(fmt.Sprintf("| %s | %s | %s | %s | %s |\n", r.c.Name, r.c.Repo, r.rel.Tag, offStr, gapStr))
	}

	os.WriteFile(*reportFile, []byte(sb.String()), 0o644)
	gapData, _ := json.MarshalIndent(gaps, "", "  ")
	os.WriteFile(*gapsFile, gapData, 0o644)

	// 汇总
	withGap := map[string]int{}
	for _, g := range gaps {
		repo := g["repo"].(string)
		withGap[repo] = len(g["gaps"].([]string))
	}
	fmt.Printf("✅ 报告: %s（%d 个包，其中 %d 个存在缺口）\n", *reportFile, len(cands), len(gaps))
	fmt.Printf("✅ 缺口清单: %s\n", *gapsFile)
	for repo, n := range withGap {
		fmt.Printf("   🟢 %s: %d 个缺口\n", repo, n)
	}
	// 按缺口数排序输出最值得构建的
	keys := make([]string, 0, len(withGap))
	for k := range withGap {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return withGap[keys[i]] > withGap[keys[j]] })
	if len(keys) > 0 {
		fmt.Printf("\n🏆 缺口最多的包（优先构建候选）:\n")
		for _, k := range keys {
			fmt.Printf("   %s (%d)\n", k, withGap[k])
		}
	}
}

func suitesFrom(c Candidate) []string {
	seen := map[string]bool{}
	var out []string
	for _, loc := range c.FoundIn {
		parts := strings.SplitN(loc, "/", 2)
		if len(parts) == 2 && !seen[parts[0]] {
			seen[parts[0]] = true
			out = append(out, parts[0])
		}
	}
	if len(out) == 0 {
		out = []string{"bookworm", "trixie"} // 兜底：矩阵里的套件
	}
	return out
}

func fetchRelease(client *http.Client, repo string) (ReleaseInfo, error) {
	type asset struct {
		Name string `json:"name"`
	}
	type full struct {
		Tag    string  `json:"tag_name"`
		Assets []asset `json:"assets"`
	}
	u := "https://api.github.com/repos/" + repo + "/releases/latest"
	req, _ := http.NewRequest("GET", u, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "deb-builder/0.1")
	if tok := os.Getenv("GITHUB_TOKEN"); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := client.Do(req)
	if err != nil {
		return ReleaseInfo{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return ReleaseInfo{}, nil // 无 release
	}
	if resp.StatusCode != http.StatusOK {
		return ReleaseInfo{}, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var f full
	if err := json.NewDecoder(resp.Body).Decode(&f); err != nil {
		return ReleaseInfo{}, err
	}
	rel := ReleaseInfo{Tag: f.Tag}
	seen := map[string]bool{}
	for _, a := range f.Assets {
		if !strings.HasSuffix(a.Name, ".deb") {
			continue
		}
		for _, t := range archTokens {
			if strings.Contains(a.Name, "_"+t.pat+".") || strings.Contains(a.Name, t.pat+".deb") {
				if !seen[t.arch] {
					rel.DebArcs = append(rel.DebArcs, t.arch)
					seen[t.arch] = true
				}
				break
			}
		}
	}
	return rel, nil
}

func containsStr(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
