package downloads

import (
	"errors"
	"reflect"
	"testing"
)

func TestTaskUpdateFieldsAllowOnlyExplicitTaskStateColumns(t *testing.T) {
	sets, values, err := taskUpdateFields("status", StatusRunning, "gid", "test-gid", "total_bytes", int64(42))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(sets, []string{"status=?", "gid=?", "total_bytes=?"}) {
		t.Fatalf("unexpected update fields: %v", sets)
	}
	if !reflect.DeepEqual(values, []any{StatusRunning, "test-gid", int64(42)}) {
		t.Fatalf("unexpected bind args: %v", values)
	}
}

func TestTaskUpdateFieldsRejectsUnscopedOrSQLIdentiferInputs(t *testing.T) {
	tests := []struct {
		name   string
		values []any
	}{
		{"empty update", nil},
		{"odd arguments", []any{"status"}},
		{"non-string column", []any{1, "value"}},
		{"owner mutation", []any{"owner", 999}},
		{"root mutation", []any{"root_binding", "{}"}},
		{"SQL statement injection", []any{"status=?, owner=999 --", StatusCompleted}},
		{"unsupported column", []any{"created_at", int64(1)}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := taskUpdateFields(test.values...)
			if !errors.Is(err, ErrInput) {
				t.Fatalf("expected ErrInput, got %v", err)
			}
		})
	}
}
