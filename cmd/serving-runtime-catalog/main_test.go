package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRegenerateCommittedCatalog(t *testing.T) {
	t.Chdir("../..")
	output := filepath.Join(t.TempDir(), "catalog.yaml")
	index := "data/redhat-serving-runtimes-index.yaml"
	if err := generateFromIndex(index, output, false); err != nil {
		t.Fatal(err)
	}
	generated, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	committed, err := os.ReadFile("data/redhat-serving-runtimes-catalog.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(generated, committed) {
		t.Fatal("committed catalog does not match its reviewed inputs")
	}
	if err := generateFromIndex(index, output, true); err != nil {
		t.Fatal(err)
	}
	stale := []byte("source: stale\n")
	if err := os.WriteFile(output, stale, 0644); err != nil {
		t.Fatal(err)
	}
	if err := generateFromIndex(index, output, true); err == nil || !strings.Contains(err.Error(), "out of date") {
		t.Fatalf("expected stale catalog rejection, got %v", err)
	}
	unchanged, err := os.ReadFile(output)
	if err != nil || !bytes.Equal(unchanged, stale) {
		t.Fatalf("check modified the output: %v", err)
	}
}
