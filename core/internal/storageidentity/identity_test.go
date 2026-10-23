package storageidentity

import "testing"

func TestBindingAllowsUnavailableMacOSGeneration(t *testing.T) {
	// macOS st_gen can be hidden from unprivileged processes. Zero is not a
	// valid reason to reject a binding with an otherwise stable physical ID.
	bound := Binding{
		Path: "/Volumes/NAS/Photos", VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: 173, BirthSec: 1700000000, BirthNsec: 123, Generation: 0,
	}
	if err := bound.Validate(); err != nil {
		t.Fatalf("valid binding with st_gen=0 rejected: %v", err)
	}
	moved := bound
	moved.Path = "/Volumes/NAS-Renamed/Photos"
	if !SameObject(bound, moved) {
		t.Fatal("directory renaming must not change physical identity")
	}
	if Equal(bound, moved) {
		t.Fatal("a changed path must not be silently accepted as identical binding")
	}
	different := bound
	different.BirthNsec++
	if SameObject(bound, different) {
		t.Fatal("reused inode with different birth time must be rejected")
	}
	different = bound
	different.VolumeUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	if SameObject(bound, different) {
		t.Fatal("different physical volume must be rejected")
	}
}
