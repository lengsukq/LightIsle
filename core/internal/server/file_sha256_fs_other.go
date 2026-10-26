//go:build !darwin

package server

import "os"

// The large-file range verifier currently relies on Darwin's APFS identity
// and generation fields. Other platforms keep the legacy bounded verifier.
func fileSystemIsAPFS(_ *os.File) (bool, error) { return false, nil }
