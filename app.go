package poskad

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/json"
	"fmt"
	"html"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const pageSize = 12

var sharedURLPattern = regexp.MustCompile(`https?://[^\s<>"']+`)

// Config controls the HTTP service and generator paths.
//
// The zero-value fields are populated by ConfigFromEnv when using Run. The
// command-line interface uses that function for its flag defaults, so explicit
// flags always take precedence over environment variables.
type Config struct {
	Port         string
	OutputDir    string
	OG2PNGScript string
	WorkDir      string
}

//go:embed web/templates/index.html web/static
var embedded embed.FS

type app struct {
	outputDir string
	script    string
	workDir   string
	templates *template.Template

	jobsMu sync.RWMutex
	jobs   map[string]*job

	urlLocksMu sync.Mutex
	urlLocks   map[string]*sync.Mutex
}

type job struct {
	mu        sync.RWMutex
	id        string
	url       string
	status    string
	logs      []string
	createdAt time.Time
	item      *historyItem
}

type historyItem struct {
	ID            string `json:"id"`
	URL           string `json:"url"`
	ImageURL      string `json:"image_url"`
	LightImageURL string `json:"light_image_url"`
	DarkImageURL  string `json:"dark_image_url"`
}

type historyPage struct {
	Items []historyItem
	Next  string
}

type indexData struct {
	History  historyPage
	SiteURL  string
	ShareURL string
}

type jobView struct {
	ID      string
	Status  string
	LogText string
	Item    *historyItem
}

// Run starts the HTTP service using environment-based configuration.
func Run() error {
	return RunWithConfig(ConfigFromEnv())
}

// ConfigFromEnv returns the service configuration from its supported
// environment variables.
func ConfigFromEnv() Config {
	return Config{
		Port:         envOr("PORT", "8080"),
		OutputDir:    envOr("OUTPUT_DIR", "output"),
		OG2PNGScript: envOr("OG2PNG_SCRIPT", "./og2png.sh"),
		WorkDir:      envOr("WORK_DIR", "."),
	}
}

// RunWithConfig starts the HTTP service with an explicit configuration.
func RunWithConfig(config Config) error {
	outputDir := config.OutputDir
	script := config.OG2PNGScript
	workDir := config.WorkDir

	absOutput, err := filepath.Abs(outputDir)
	if err != nil {
		return err
	}
	absWorkDir, err := filepath.Abs(workDir)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(absOutput, 0o755); err != nil {
		return err
	}

	templates, err := template.ParseFS(embedded, "web/templates/index.html")
	if err != nil {
		return err
	}

	a := &app{
		outputDir: absOutput,
		script:    script,
		workDir:   absWorkDir,
		templates: templates,
		jobs:      make(map[string]*job),
		urlLocks:  make(map[string]*sync.Mutex),
	}

	static, err := fs.Sub(embedded, "web/static")
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.Handle("/static/", http.StripPrefix("/static/", cacheStatic(http.FileServer(http.FS(static)))))
	mux.HandleFunc("/", a.handleIndex)
	mux.HandleFunc("/share", a.handleShare)
	mux.HandleFunc("/generate", a.handleGenerate)
	mux.HandleFunc("/jobs/", a.handleJob)
	mux.HandleFunc("/history", a.handleHistory)
	mux.HandleFunc("/items/", a.handleItem)
	mux.HandleFunc("/media/", a.handleMedia)

	addr := ":" + config.Port
	log.Printf("og2png web listening on %s (output: %s)", addr, absOutput)
	return http.ListenAndServe(addr, securityHeaders(mux))
}

func (a *app) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	a.renderTemplate(w, "index", indexData{
		History:  a.historyPage(""),
		SiteURL:  requestBaseURL(r),
		ShareURL: sharedSourceURL(r.URL.Query()),
	})
}

// handleShare receives a Web Share Target request from an installed PWA.
// Redirecting to the homepage keeps the resulting card in the normal UI while
// preserving the shared link long enough for the browser to submit it.
func (a *app) handleShare(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(10 << 20); err != nil {
		http.Error(w, "invalid share target request", http.StatusBadRequest)
		return
	}
	sharedURL := sharedSourceURL(r.Form)
	if !validSourceURL(sharedURL) {
		http.Error(w, "share did not include a valid http:// or https:// link", http.StatusBadRequest)
		return
	}
	redirect := url.URL{Path: "/"}
	query := redirect.Query()
	query.Set("share", sharedURL)
	redirect.RawQuery = query.Encode()
	http.Redirect(w, r, redirect.String(), http.StatusSeeOther)
}

func (a *app) handleHistory(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	a.renderTemplate(w, "history", a.historyPage(r.URL.Query().Get("before")))
}

func (a *app) handleItem(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/items/")
	if !isUUIDv7(id) {
		http.NotFound(w, r)
		return
	}
	item, ok := a.historyItem(id)
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(item)
}

func (a *app) handleGenerate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		a.renderErrorPanel(w, "无法读取提交内容")
		return
	}
	rawURL := strings.TrimSpace(r.Form.Get("url"))
	if !validSourceURL(rawURL) {
		a.renderErrorPanel(w, "请输入有效的 http:// 或 https:// 链接")
		return
	}
	j := &job{id: uuidV7(), url: rawURL, status: "queued", createdAt: time.Now()}
	j.appendLog("任务已创建，等待生成器启动…")
	a.jobsMu.Lock()
	a.jobs[j.id] = j
	a.jobsMu.Unlock()
	go a.runJob(j)
	a.renderJob(w, j)
}

func (a *app) handleJob(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/jobs/")
	a.jobsMu.RLock()
	j := a.jobs[id]
	a.jobsMu.RUnlock()
	if j == nil {
		http.NotFound(w, r)
		return
	}
	a.renderJob(w, j)
	if snapshot := j.snapshot(); snapshot.Status == "succeeded" && snapshot.Item != nil {
		a.renderTemplate(w, "card-oob", *snapshot.Item)
	}
}

func (a *app) handleMedia(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/media/"), "/")
	if len(parts) != 2 || !isUUIDv7(parts[0]) || !validImageName(parts[1]) {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(a.outputDir, parts[0], parts[1])
	if _, err := os.Stat(path); err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeFile(w, r, path)
}

func (a *app) runJob(j *job) {
	lock := a.lockForURL(j.url)
	j.appendLog("等待该原文链接的生成锁…")
	lock.Lock()
	defer lock.Unlock()

	j.setStatus("running")
	j.appendLog("已取得生成锁。")
	dir := filepath.Join(a.outputDir, j.id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		j.fail(fmt.Sprintf("创建输出目录失败: %v", err))
		return
	}
	if err := os.WriteFile(filepath.Join(dir, "src.url"), []byte(j.url+"\n"), 0o644); err != nil {
		j.fail(fmt.Sprintf("写入原文链接失败: %v", err))
		return
	}

	imagePath := filepath.Join(dir, "image.png")
	cmd := exec.Command(a.script, "--theme=light,dark", j.url, imagePath)
	cmd.Dir = a.workDir
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		j.fail(fmt.Sprintf("打开日志管道失败: %v", err))
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		j.fail(fmt.Sprintf("打开错误日志管道失败: %v", err))
		return
	}
	if err := cmd.Start(); err != nil {
		j.fail(fmt.Sprintf("无法启动 og2png.sh: %v", err))
		return
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go streamLogs(&wg, stdout, j)
	go streamLogs(&wg, stderr, j)
	err = cmd.Wait()
	wg.Wait()
	if err != nil {
		j.fail(fmt.Sprintf("生成失败: %v", err))
		return
	}
	if _, err := os.Stat(filepath.Join(dir, "image.light.png")); err != nil {
		j.fail("生成器没有产出 image.light.png")
		return
	}
	if _, err := os.Stat(filepath.Join(dir, "image.dark.png")); err != nil {
		j.fail("生成器没有产出 image.dark.png")
		return
	}
	j.succeed(historyItem{
		ID:            j.id,
		URL:           j.url,
		ImageURL:      "/media/" + j.id + "/image.png",
		LightImageURL: "/media/" + j.id + "/image.light.png",
		DarkImageURL:  "/media/" + j.id + "/image.dark.png",
	})
}

func streamLogs(wg *sync.WaitGroup, r interface{ Read([]byte) (int, error) }, j *job) {
	defer wg.Done()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 1024), 1024*1024)
	for scanner.Scan() {
		j.appendLog(scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		j.appendLog("读取生成日志失败: " + err.Error())
	}
}

func (a *app) lockForURL(rawURL string) *sync.Mutex {
	key := fmt.Sprintf("%x", sha256.Sum256([]byte(rawURL)))
	a.urlLocksMu.Lock()
	defer a.urlLocksMu.Unlock()
	if lock := a.urlLocks[key]; lock != nil {
		return lock
	}
	lock := &sync.Mutex{}
	a.urlLocks[key] = lock
	return lock
}

func (a *app) historyPage(before string) historyPage {
	entries, err := os.ReadDir(a.outputDir)
	if err != nil {
		return historyPage{}
	}
	items := make([]historyItem, 0)
	for _, entry := range entries {
		if !entry.IsDir() || !isUUIDv7(entry.Name()) || (before != "" && entry.Name() >= before) {
			continue
		}
		item, ok := a.historyItem(entry.Name())
		if !ok {
			continue
		}
		items = append(items, item)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ID > items[j].ID })
	page := historyPage{}
	if len(items) > pageSize {
		page.Items = items[:pageSize]
		page.Next = page.Items[len(page.Items)-1].ID
	} else {
		page.Items = items
	}
	return page
}

func (a *app) historyItem(id string) (historyItem, bool) {
	dir := filepath.Join(a.outputDir, id)
	if _, err := os.Stat(filepath.Join(dir, "image.png")); err != nil {
		return historyItem{}, false
	}
	rawURL, err := os.ReadFile(filepath.Join(dir, "src.url"))
	if err != nil {
		return historyItem{}, false
	}
	itemURL := strings.TrimSpace(string(rawURL))
	if !validSourceURL(itemURL) {
		return historyItem{}, false
	}
	item := historyItem{
		ID:            id,
		URL:           itemURL,
		ImageURL:      "/media/" + id + "/image.png",
		LightImageURL: "/media/" + id + "/image.light.png",
		DarkImageURL:  "/media/" + id + "/image.dark.png",
	}
	if _, err := os.Stat(filepath.Join(dir, "image.light.png")); err != nil {
		item.LightImageURL = item.ImageURL
	}
	if _, err := os.Stat(filepath.Join(dir, "image.dark.png")); err != nil {
		item.DarkImageURL = item.ImageURL
	}
	return item, true
}

func (a *app) renderJob(w http.ResponseWriter, j *job) {
	a.renderTemplate(w, "job", j.snapshot())
}

func (a *app) renderErrorPanel(w http.ResponseWriter, message string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<section id="job-panel" class="job-panel failed">%s</section>`, html.EscapeString(message))
}

func (a *app) renderTemplate(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := a.templates.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

func (j *job) appendLog(line string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if len(j.logs) >= 300 {
		j.logs = j.logs[len(j.logs)-299:]
	}
	j.logs = append(j.logs, line)
}

func (j *job) setStatus(status string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.status = status
}

func (j *job) fail(message string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.logs = append(j.logs, message)
	j.status = "failed"
}

func (j *job) succeed(item historyItem) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.item = &item
	j.logs = append(j.logs, "✓ 已生成: "+item.ImageURL)
	j.status = "succeeded"
}

func (j *job) snapshot() jobView {
	j.mu.RLock()
	defer j.mu.RUnlock()
	return jobView{ID: j.id, Status: j.status, LogText: strings.Join(j.logs, "\n"), Item: j.item}
}

func validSourceURL(raw string) bool {
	u, err := url.ParseRequestURI(raw)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}

func validImageName(name string) bool {
	return name == "image.png" || name == "image.light.png" || name == "image.dark.png"
}

// sharedSourceURL accepts an existing share redirect first, then the explicit
// Web Share Target URL field, and finally a link embedded in text or title.
func sharedSourceURL(values url.Values) string {
	for _, key := range []string{"share", "url", "text", "title"} {
		for _, value := range values[key] {
			value = strings.TrimSpace(value)
			if validSourceURL(value) {
				return value
			}
			for _, candidate := range sharedURLPattern.FindAllString(value, -1) {
				candidate = strings.TrimRight(candidate, ".,;:!?)]}。！？，；：")
				if validSourceURL(candidate) {
					return candidate
				}
			}
		}
	}
	return ""
}

func uuidV7() string {
	var b [16]byte
	ms := uint64(time.Now().UnixMilli())
	for i := 5; i >= 0; i-- {
		b[i] = byte(ms)
		ms >>= 8
	}
	if _, err := rand.Read(b[6:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x70
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func isUUIDv7(id string) bool {
	if len(id) != 36 || id[14] != '7' || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' {
		return false
	}
	for i, c := range id {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			continue
		}
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func requestBaseURL(r *http.Request) string {
	scheme := "http"
	if forwarded := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0]); forwarded != "" {
		scheme = forwarded
	} else if r.TLS != nil {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		next.ServeHTTP(w, r)
	})
}

func cacheStatic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		next.ServeHTTP(w, r)
	})
}
