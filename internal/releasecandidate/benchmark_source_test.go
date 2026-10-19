package releasecandidate

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateAndStageFetchesQualifiedRevision(t *testing.T) {
	cfg := newGitCandidate(t)
	// The default branch advances after qualification. Its contents must not be
	// used in place of the immutable revision recorded in the report.
	writeFile(t, filepath.Join(cfg.BenchmarkRepository, "data", "manifest.json"), "invalid newer data", 0o644)
	benchmarkGit(t, cfg.BenchmarkRepository, "commit", "--quiet", "-am", "unqualified update")
	fetchTemp := t.TempDir()
	t.Setenv("TMPDIR", fetchTemp)

	report, err := ValidateAndStage(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if report.BenchmarkFiles != 4 || report.BenchmarkModels != 1 {
		t.Fatalf("unexpected staged payload: %+v", report)
	}
	metadata := filepath.Join(cfg.OutputDir, "app", "benchmarks", "example", "model", "metadata.json")
	assertMode(t, metadata, 0o644)
	if _, err := os.Stat(filepath.Join(cfg.OutputDir, "app", "benchmarks", ".git")); !os.IsNotExist(err) {
		t.Fatalf("Git checkout must not enter image payload: %v", err)
	}
	assertCheckoutRemoved(t, fetchTemp)
}

func TestFetchedBenchmarksStillRequireReleaseValidation(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*testing.T, Config)
		want   string
	}{
		{"payload digest", func(t *testing.T, cfg Config) {
			editSourceReport(t, cfg, func(report *qualificationReport) { report.PayloadSHA256 = strings.Repeat("0", 64) })
		}, "payload_sha256 does not match"},
		{"loader failure", func(t *testing.T, cfg Config) {
			writeFile(t, filepath.Join(cfg.LoaderCheckDir, "fixture-v1"), "#!/bin/sh\nexit 1\n", 0o755)
		}, "loader"},
		{"missing revision", func(t *testing.T, cfg Config) {
			editSourceReport(t, cfg, func(report *qualificationReport) {
				report.BenchmarkRevision = strings.Repeat("f", 40)
				report.Source.Revision = report.BenchmarkRevision
			})
		}, "git fetch failed"},
		{"missing manifest", func(t *testing.T, cfg Config) {
			benchmarkGit(t, cfg.BenchmarkRepository, "rm", "data/manifest.json")
			benchmarkGit(t, cfg.BenchmarkRepository, "commit", "--quiet", "-m", "remove manifest")
			editSourceReport(t, cfg, func(report *qualificationReport) {
				report.BenchmarkRevision = benchmarkGit(t, cfg.BenchmarkRepository, "rev-parse", "HEAD")
				report.Source.Revision = report.BenchmarkRevision
			})
		}, "data/manifest.json"},
	} {
		t.Run(test.name, func(t *testing.T) {
			cfg := newGitCandidate(t)
			test.mutate(t, cfg)
			fetchTemp := t.TempDir()
			t.Setenv("TMPDIR", fetchTemp)
			_, err := ValidateAndStage(cfg)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected %q, got %v", test.want, err)
			}
			if _, err := os.Stat(cfg.OutputDir); !os.IsNotExist(err) {
				t.Fatalf("failed validation must not stage an image payload: %v", err)
			}
			assertCheckoutRemoved(t, fetchTemp)
		})
	}
}

func TestFetchRejectsUnqualifiedReportsBeforeGit(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*qualificationReport)
	}{
		{"fixture", func(r *qualificationReport) { r.QualificationMode = "fixture" }},
		{"not promotable", func(r *qualificationReport) { r.PromotionEligible = false }},
		{"unapproved", func(r *qualificationReport) { r.Exclusions.ReviewStatus = "pending" }},
		{"mutable ref", func(r *qualificationReport) { r.BenchmarkRevision = "main" }},
		{"revision mismatch", func(r *qualificationReport) { r.Source.Revision = strings.Repeat("a", 40) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			cfg := newTestCandidate(t, "example/model")
			editSourceReport(t, cfg, test.mutate)
			t.Setenv("PATH", t.TempDir()) // Git cannot run: rejection must precede it.
			_, err := fetchBenchmarkData("unused", cfg.BenchmarkQualificationReport)
			if err == nil || !strings.Contains(err.Error(), "fetch benchmark data requires") {
				t.Fatalf("expected report rejection before Git, got %v", err)
			}
		})
	}
}

func TestLocalBenchmarkPayloadDoesNotFetch(t *testing.T) {
	cfg := newTestCandidate(t, "example/model")
	cfg.BenchmarkRepository = filepath.Join(t.TempDir(), "nonexistent-repository")
	if _, err := ValidateAndStage(cfg); err != nil {
		t.Fatal(err)
	}
}

func newGitCandidate(t *testing.T) Config {
	t.Helper()
	cfg := newTestCandidate(t, "example/model")
	cfg.BenchmarkRepository = t.TempDir()
	if err := os.Rename(cfg.BenchmarkDir, filepath.Join(cfg.BenchmarkRepository, "data")); err != nil {
		t.Fatal(err)
	}
	benchmarkGit(t, cfg.BenchmarkRepository, "init", "--quiet")
	benchmarkGit(t, cfg.BenchmarkRepository, "add", "data")
	benchmarkGit(t, cfg.BenchmarkRepository, "commit", "--quiet", "-m", "qualified data")
	editSourceReport(t, cfg, func(report *qualificationReport) {
		report.BenchmarkRevision = benchmarkGit(t, cfg.BenchmarkRepository, "rev-parse", "HEAD")
		report.Source.Revision = report.BenchmarkRevision
	})
	cfg.BenchmarkDir = ""
	return cfg
}

func benchmarkGit(t *testing.T, repository string, args ...string) string {
	t.Helper()
	args = append([]string{"-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"}, args...)
	output, err := exec.Command("git", args...).CombinedOutput()
	if err != nil {
		t.Fatalf("git failed: %v\n%s", err, output)
	}
	return strings.TrimSpace(string(output))
}

func editSourceReport(t *testing.T, cfg Config, edit func(*qualificationReport)) {
	t.Helper()
	data, err := os.ReadFile(cfg.BenchmarkQualificationReport)
	if err != nil {
		t.Fatal(err)
	}
	var report qualificationReport
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	edit(&report)
	data, err = json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, cfg.BenchmarkQualificationReport, string(data), 0o644)
}

func assertCheckoutRemoved(t *testing.T, root string) {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatalf("temporary checkout was not removed: %v, %v", entries, err)
	}
}
