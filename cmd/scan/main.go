// 扫描器：下载 Debian Packages 索引，找出 Homepage 为 GitHub 的软件包
package main

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Candidate struct {
	Repo       string            `json:"repo"`  // owner/repo（GitHub）
	Name       string            `json:"name"`  // Debian 包名（主要）
	Names      []string          `json:"names"` // 该 GitHub 仓库对应的 Debian 包名（可能多个）
	Homepage   string            `json:"homepage"`
	Section    string            `json:"section"`
	Summary    string            `json:"summary"`                   // Description 第一行
	FoundIn    []string          `json:"found_in"`                  // 出现位置：suite/arch
	DebianVers map[string]string `json:"debian_versions,omitempty"` // suite/arch -> 版本
}

func main() {
	outFile := flag.String("out", "candidates.json", "输出文件")
	limit := flag.Int("limit", 0, "最多输出多少条（0=不限）")
	suite := flag.String("suite", "", "只扫描指定套件（测试用）")
	arch := flag.String("arch", "", "只扫描指定架构（测试用）")
	suitesFile := flag.String("suites", "conf/suites.txt", "套件×架构矩阵文件")
	cacheDir := flag.String("cache", "/tmp/deb-index", "Packages 索引缓存目录")
	local := flag.String("local", "", "直接读取本地 Packages 文件（测试用，跳过下载）")
	flag.Parse()

	if err := os.MkdirAll(*cacheDir, 0o755); err != nil {
		fatal(err)
	}

	byRepo := map[string]*Candidate{}
	var order []string
	if *local != "" {
		s := *suite
		a := *arch
		if s == "" || a == "" {
			fatal(fmt.Errorf("-local 需要同时指定 -suite 和 -arch"))
		}
		n, err := parseIndex(*local, s, a, byRepo, &order)
		if err != nil {
			fatal(err)
		}
		fmt.Printf("✅ 本地文件 %s/%s: %d 个 GitHub 包\n", s, a, n)
	} else {
		matrix := loadMatrix(*suitesFile, *suite, *arch)
		fmt.Printf("扫描矩阵：%d 个 suite/arch 组合\n", len(matrix))
		for _, m := range matrix {
			path, err := fetchIndex(m.suite, m.arch, *cacheDir)
			if err != nil {
				fmt.Fprintf(os.Stderr, "⚠️  %s/%s: %v\n", m.suite, m.arch, err)
				continue
			}
			n, err := parseIndex(path, m.suite, m.arch, byRepo, &order)
			if err != nil {
				fmt.Fprintf(os.Stderr, "⚠️  %s/%s 解析: %v\n", m.suite, m.arch, err)
				continue
			}
			fmt.Printf("✅ %s/%s: %d 个 GitHub 包\n", m.suite, m.arch, n)
		}
	}

	cands := make([]*Candidate, 0, len(order))
	for _, r := range order {
		cands = append(cands, byRepo[r])
	}
	sort.Slice(cands, func(i, j int) bool { return len(cands[j].FoundIn) < len(cands[i].FoundIn) })
	if *limit > 0 && len(cands) > *limit {
		cands = cands[:*limit]
	}

	data, _ := json.MarshalIndent(cands, "", "  ")
	if err := os.WriteFile(*outFile, data, 0o644); err != nil {
		fatal(err)
	}
	fmt.Printf("\n📦 共 %d 个候选，已写入 %s\n", len(cands), *outFile)
}

// ---- 套件×架构矩阵 ----

type mat struct{ suite, arch string }

func loadMatrix(path, suiteOnly, archOnly string) []mat {
	f, err := os.Open(path)
	if err != nil {
		fatal(err)
	}
	defer f.Close()
	var out []mat
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) != 2 {
			continue
		}
		if suiteOnly != "" && parts[0] != suiteOnly {
			continue
		}
		if archOnly != "" && parts[1] != archOnly {
			continue
		}
		out = append(out, mat{parts[0], parts[1]})
	}
	if len(out) == 0 {
		fatal(fmt.Errorf("矩阵为空"))
	}
	return out
}

// ---- 下载 Packages 索引 ----

var client = &http.Client{Timeout: 15 * time.Minute}

func fetchIndex(suite, arch, cacheDir string) (string, error) {
	base := fmt.Sprintf("deb.debian.org/debian/dists/%s/main/binary-%s/Packages", suite, arch)
	for _, ext := range []string{".xz", ".gz", ""} {
		dest := filepath.Join(cacheDir, fmt.Sprintf("%s-%s-Packages%s", suite, arch, ext))
		if _, err := os.Stat(dest); err == nil {
			return dest, nil // 已有缓存
		}
		u := "https://" + base + ext
		fmt.Printf("   ⬇️  %s\n", u)
		if err := download(u, dest); err != nil {
			fmt.Fprintf(os.Stderr, "     重试下一个格式: %v\n", err)
			continue
		}
		return dest, nil
	}
	return "", fmt.Errorf("所有格式下载失败")
}

func download(u, dest string) error {
	req, _ := http.NewRequest("GET", u, nil)
	req.Header.Set("User-Agent", "deb-builder/0.1 (LeisureLinux)")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	tmp := dest + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, resp.Body)
	out.Close()
	if err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

// ---- 解析 Packages（支持 .xz / .gz / 明文） ----

func parseIndex(path, suite, arch string, byRepo map[string]*Candidate, order *[]string) (int, error) {
	var r io.Reader
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	switch {
	case strings.HasSuffix(path, ".xz"):
		cmd := exec.Command("xz", "-dc", path)
		rc, err := cmd.StdoutPipe()
		if err != nil {
			return 0, err
		}
		if err := cmd.Start(); err != nil {
			return 0, err
		}
		defer cmd.Wait()
		r = rc
	case strings.HasSuffix(path, ".gz"):
		gz, err := gzip.NewReader(f)
		if err != nil {
			return 0, err
		}
		defer gz.Close()
		r = gz
	default:
		r = f
	}
	return parseStanzas(r, suite, arch, byRepo, order)
}

func parseStanzas(r io.Reader, suite, arch string, byRepo map[string]*Candidate, order *[]string) (int, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1024*1024), 4*1024*1024)
	var cur map[string]string
	flush := func() {
		if cur == nil {
			return
		}
		home := cur["Homepage"]
		repo := githubRepo(home)
		if repo != "" {
			key := repo
			c, ok := byRepo[key]
			if !ok {
				c = &Candidate{
					Repo:       repo,
					Name:       cur["Package"],
					Homepage:   home,
					Section:    cur["Section"],
					DebianVers: map[string]string{},
				}
				byRepo[key] = c
				*order = append(*order, key)
			}
			c.Names = appendUnique(c.Names, cur["Package"])
			loc := suite + "/" + arch
			c.FoundIn = appendUnique(c.FoundIn, loc)
			if v := cur["Version"]; v != "" {
				c.DebianVers[loc] = v
			}
			if c.Summary == "" {
				c.Summary = firstLine(cur["Description"])
			}
		}
		cur = nil
	}
	lastKey := ""
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			flush()
			continue
		}
		if strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") {
			if lastKey != "" {
				cur[lastKey] += "\n" + strings.TrimSpace(line)
			}
			continue
		}
		idx := strings.Index(line, ":")
		if idx <= 0 {
			continue
		}
		if cur == nil {
			cur = map[string]string{}
		}
		k, v := line[:idx], strings.TrimSpace(line[idx+1:])
		cur[k] = v
		lastKey = k
	}
	flush()
	return len(byRepo), sc.Err()
}

// ---- 工具函数 ----

func githubRepo(homepage string) string {
	h := strings.TrimSpace(homepage)
	if h == "" {
		return ""
	}
	u, err := url.Parse(h)
	if err != nil || u.Host != "github.com" {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return ""
	}
	// 忽略纯用户主页（如 github.com/user 只有一个段）
	if len(parts) == 2 && strings.Contains(parts[1], ".") {
		return ""
	}
	return parts[0] + "/" + parts[1]
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func appendUnique(list []string, v string) []string {
	for _, x := range list {
		if x == v {
			return list
		}
	}
	return append(list, v)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "❌", err)
	os.Exit(1)
}
