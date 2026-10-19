package releasecandidate

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Fetch the immutable source named by the producer's report. The caller must
// still validate the fetched data against that report before staging any bytes.
// Authentication uses the host's Git credential helper or SSH configuration;
// neither the checkout nor its Git configuration enters the image build context.
func fetchBenchmarkData(repository, reportPath string) (checkout string, err error) {
	reportData, err := readRegularFile(reportPath)
	if err != nil {
		return "", err
	}
	var report qualificationReport
	if err := decodeSingleJSON(reportPath, reportData, &report); err != nil {
		return "", err
	}
	if report.QualificationMode != "release" || !report.PromotionEligible || report.Exclusions.ReviewStatus != "approved" {
		return "", fmt.Errorf("fetch benchmark data requires an approved, promotion-eligible release qualification report")
	}
	if !immutableRevision.MatchString(report.BenchmarkRevision) || report.Source.Revision != report.BenchmarkRevision {
		return "", fmt.Errorf("fetch benchmark data requires matching immutable benchmark_revision and source.revision in the qualification report")
	}
	checkout, err = os.MkdirTemp("", "ai-hub-benchmark-data-")
	if err != nil {
		return "", fmt.Errorf("create benchmark checkout: %w", err)
	}
	root := checkout
	defer func() {
		if err != nil {
			os.RemoveAll(root)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	runGit := func(args ...string) (string, error) {
		cmd := exec.CommandContext(ctx, "git", args...)
		cmd.Dir = checkout
		cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
		cmd.WaitDelay = 5 * time.Second
		output, err := cmd.CombinedOutput()
		if err != nil {
			return "", fmt.Errorf("benchmark checkout git %s failed (check repository access and Git credentials): %w\n%s", args[0], err, output)
		}
		return strings.TrimSpace(string(output)), nil
	}
	objectFormat := "sha1"
	if len(report.BenchmarkRevision) == 64 {
		objectFormat = "sha256"
	}
	if _, err = runGit("init", "--quiet", "--object-format="+objectFormat); err != nil {
		return "", err
	}
	if _, err = runGit("fetch", "--quiet", "--depth=1", "--no-tags", "--", repository, report.BenchmarkRevision); err != nil {
		return "", err
	}
	if _, err = runGit("checkout", "--quiet", "--detach", "FETCH_HEAD"); err != nil {
		return "", err
	}
	revision, err := runGit("rev-parse", "HEAD")
	if err != nil {
		return "", err
	}
	if revision != report.BenchmarkRevision {
		return "", fmt.Errorf("fetched benchmark revision %s does not match qualification report %s", revision, report.BenchmarkRevision)
	}
	dataDir, err := os.Lstat(filepath.Join(checkout, "data"))
	if err != nil || !dataDir.IsDir() {
		return "", fmt.Errorf("benchmark repository must contain a data directory, not a symlink")
	}
	manifest, err := os.Lstat(filepath.Join(checkout, "data", "manifest.json"))
	if err != nil || !manifest.Mode().IsRegular() || manifest.Size() == 0 {
		return "", fmt.Errorf("benchmark repository must contain a nonempty regular data/manifest.json")
	}
	return checkout, nil
}
