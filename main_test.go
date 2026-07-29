package main

import (
	"os"
	"path/filepath"
	"testing"
)

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
