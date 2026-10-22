package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"

	"github.com/opendatahub-io/model-metadata-collection/internal/servingruntime"
)

func main() {
	input := flag.String("input", "data/redhat-serving-runtimes-index.yaml", "reviewed runtime index")
	output := flag.String("output", "data/redhat-serving-runtimes-catalog.yaml", "generated loader catalog")
	check := flag.Bool("check", false, "verify checked-in output without changing it")
	flag.Parse()
	if err := generateFromIndex(*input, *output, *check); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func generateFromIndex(inputPath, outputPath string, check bool) error {
	input, err := os.ReadFile(inputPath)
	if err != nil {
		return err
	}
	output, err := servingruntime.GenerateServingRuntimeCatalog(input, os.DirFS("."))
	if err != nil {
		return err
	}
	result, err := servingruntime.ValidateServingRuntimeCatalogSchema(context.Background(), output)
	if err != nil {
		return err
	}
	if err := writeRuntimeArtifacts(map[string][]byte{outputPath: output}, check); err != nil {
		return err
	}
	fmt.Printf("%s: %d runtimes, %d versions validated against model-registry schemas at %s\n", outputPath, result.Runtimes, result.Versions, servingruntime.ServingRuntimeSchemaRevision)
	return nil
}

func writeRuntimeArtifacts(files map[string][]byte, check bool) error {
	paths := slices.Sorted(maps.Keys(files))
	if check {
		for _, file := range paths {
			existing, err := os.ReadFile(file)
			if err != nil {
				return err
			}
			if !bytes.Equal(existing, files[file]) {
				return fmt.Errorf("%s is out of date; regenerate it", file)
			}
		}
		return nil
	}
	// Stage every file before replacing outputs, so generation/validation errors
	// leave the reviewed artifacts intact.
	temporary := map[string]string{}
	defer func() {
		for _, file := range temporary {
			_ = os.Remove(file)
		}
	}()
	for _, file := range paths {
		if err := os.MkdirAll(filepath.Dir(file), 0755); err != nil {
			return err
		}
		staged, err := os.CreateTemp(filepath.Dir(file), ".serving-runtime-*")
		if err != nil {
			return err
		}
		temporary[file] = staged.Name()
		_, writeErr := staged.Write(files[file])
		closeErr := staged.Close()
		if writeErr != nil {
			return writeErr
		}
		if closeErr != nil {
			return closeErr
		}
		if err := os.Chmod(staged.Name(), 0644); err != nil {
			return err
		}
	}
	for _, file := range paths {
		if err := os.Rename(temporary[file], file); err != nil {
			return err
		}
	}
	return nil
}
