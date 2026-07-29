package poskad

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

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
