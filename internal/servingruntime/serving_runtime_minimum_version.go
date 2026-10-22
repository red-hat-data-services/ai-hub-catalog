package servingruntime

import (
	"fmt"
	"regexp"

	"github.com/Masterminds/semver/v3"
)

var rhoaiReleaseTag = regexp.MustCompile(`^v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?:[-+].*)?$`)

func validateMinimumRHOAIVersion(value string) error {
	if value == "" {
		return nil
	}
	parts := rhoaiReleaseTag.FindStringSubmatch(value)
	if len(parts) != 2 {
		return fmt.Errorf("minimumRHOAIVersion %q must be a release version, such as 3.6", value)
	}
	if _, err := semver.NewVersion(value); err != nil {
		return fmt.Errorf("invalid minimumRHOAIVersion %q: %w", value, err)
	}
	return nil
}
