package poskad

import (
	"bytes"
	"html/template"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCardOOBPreservesCardWrapper(t *testing.T) {
	templates, err := template.ParseFS(embedded, "web/templates/index.html")
	if err != nil {
		t.Fatal(err)
	}
	item := historyItem{ID: "019fad39-0000-7000-8000-000000000000", URL: "https://example.com", ImageURL: "/media/test/image.png"}
	var output bytes.Buffer
	if err := templates.ExecuteTemplate(&output, "card-oob", item); err != nil {
		t.Fatal(err)
	}
	got := output.String()
	if !strings.Contains(got, `hx-swap-oob="afterbegin:#gallery"`) || !strings.Contains(got, `class="card"`) {
		t.Fatalf("card-oob must insert a full card, got %q", got)
	}
}

func TestRequestBaseURLUsesForwardedProtocol(t *testing.T) {
	r := httptest.NewRequest("GET", "http://poskad.example/", nil)
	r.Host = "poskad.example"
	r.Header.Set("X-Forwarded-Proto", "https")
	if got, want := requestBaseURL(r), "https://poskad.example"; got != want {
		t.Fatalf("requestBaseURL() = %q, want %q", got, want)
	}
}

func TestConfigFromEnv(t *testing.T) {
	t.Setenv("PORT", "3000")
	t.Setenv("OUTPUT_DIR", "cards")
	t.Setenv("OG2PNG_SCRIPT", "/tools/og2png.sh")
	t.Setenv("WORK_DIR", "/workspace")

	got := ConfigFromEnv()
	want := Config{Port: "3000", OutputDir: "cards", OG2PNGScript: "/tools/og2png.sh", WorkDir: "/workspace"}
	if got != want {
		t.Fatalf("ConfigFromEnv() = %#v, want %#v", got, want)
	}
}

func TestSharedSourceURL(t *testing.T) {
	tests := []struct {
		name   string
		values url.Values
		want   string
	}{
		{
			name:   "explicit URL",
			values: url.Values{"url": {"https://x.com/poskad/status/1"}},
			want:   "https://x.com/poskad/status/1",
		},
		{
			name:   "URL inside shared text",
			values: url.Values{"text": {"Read this: https://x.com/poskad/status/2。"}},
			want:   "https://x.com/poskad/status/2",
		},
		{
			name:   "invalid link",
			values: url.Values{"url": {"x.com/poskad/status/3"}},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := sharedSourceURL(test.values); got != test.want {
				t.Fatalf("sharedSourceURL() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestShareTargetRedirectsToSharedURL(t *testing.T) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("text", "A post: https://x.com/poskad/status/4"); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	a := &app{}
	req := httptest.NewRequest(http.MethodPost, "/share", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	a.handleShare(response, req)

	if got, want := response.Code, http.StatusSeeOther; got != want {
		t.Fatalf("status = %d, want %d", got, want)
	}
	if got, want := response.Header().Get("Location"), "/?share=https%3A%2F%2Fx.com%2Fposkad%2Fstatus%2F4"; got != want {
		t.Fatalf("redirect = %q, want %q", got, want)
	}
}

func TestCommandFlagsOverrideEnvironment(t *testing.T) {
	t.Setenv("PORT", "8080")
	cmd := NewCommand()
	if err := cmd.ParseFlags([]string{"--port", "3000", "--output-dir", "cards"}); err != nil {
		t.Fatal(err)
	}
	if got, want := cmd.Flags().Lookup("port").Value.String(), "3000"; got != want {
		t.Fatalf("port = %q, want %q", got, want)
	}
	if got, want := cmd.Flags().Lookup("output-dir").Value.String(), "cards"; got != want {
		t.Fatalf("output-dir = %q, want %q", got, want)
	}
}

func TestUUIDV7Shape(t *testing.T) {
	id := uuidV7()
	if !isUUIDv7(id) {
		t.Fatalf("uuidV7() = %q, not a UUIDv7", id)
	}
}

func TestHistoryPageUsesTwelveNewestItems(t *testing.T) {
	root := t.TempDir()
	const suffixes = "0123456789abc"
	for i := 0; i < 13; i++ {
		id := "019fad39-0000-7000-8000-00000000000" + string(suffixes[i])
		dir := filepath.Join(root, id)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "image.png"), []byte("png"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "src.url"), []byte("https://example.com/"+id), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	a := &app{outputDir: root}
	page := a.historyPage("")
	if len(page.Items) != pageSize {
		t.Fatalf("got %d items, want %d", len(page.Items), pageSize)
	}
	if page.Next == "" {
		t.Fatal("expected cursor for thirteenth item")
	}
	if page.Items[0].ID <= page.Items[1].ID {
		t.Fatalf("items are not newest first: %q <= %q", page.Items[0].ID, page.Items[1].ID)
	}

	next := a.historyPage(page.Next)
	if len(next.Items) != 1 {
		t.Fatalf("got %d remaining items, want 1", len(next.Items))
	}
}
