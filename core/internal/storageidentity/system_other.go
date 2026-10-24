//go:build !darwin

package storageidentity

import (
	"context"
	"fmt"
	"os"
)

func MatchesDirectory(Binding, os.FileInfo) bool { return false }

// SystemProvider is intentionally unavailable outside macOS. In particular,
// a non-macOS filesystem device number is not treated as a volume UUID.
func (SystemProvider) Capture(context.Context, string) (Binding, error) {
	return Binding{}, ErrUnsupported
}

func (SystemProvider) Verify(_ context.Context, binding Binding) error {
	if err := binding.Validate(); err != nil {
		return err
	}
	return fmt.Errorf("%w: system volume identity is only available on macOS", ErrUnsupported)
}

func (SystemProvider) IsVolumeMounted(context.Context, string) (bool, error) {
	return false, ErrUnsupported
}
