package idutil

import "testing"

func TestValidRootID(t *testing.T) {
	if !ValidRootID("0123456789abcdef0123456789abcdef") {
		t.Fatal("expected valid lowercase hex root ID")
	}
	for _, bad := range []string{
		"",
		"0123456789ABCDEF0123456789ABCDEF",
		"0123456789abcdef0123456789abcde",
		"0123456789abcdef0123456789abcdef0",
		"0123456789abcdef0123456789abcdeg",
	} {
		if ValidRootID(bad) {
			t.Fatalf("expected %q to be invalid root ID", bad)
		}
	}
}

func TestValidUUID(t *testing.T) {
	if !ValidUUID("11111111-2222-3333-4444-555555555555") {
		t.Fatal("expected valid UUID")
	}
	if !ValidUUID("11111111-2222-3333-4444-AABBCCDDEEFF") {
		t.Fatal("expected uppercase hex UUID to be valid")
	}
	for _, bad := range []string{
		"",
		"11111111222233334444555555555555",
		"11111111-2222-3333-4444-55555555555z",
		"11111111-2222-3333-4444-55555555555",
	} {
		if ValidUUID(bad) {
			t.Fatalf("expected %q to be invalid UUID", bad)
		}
	}
}
