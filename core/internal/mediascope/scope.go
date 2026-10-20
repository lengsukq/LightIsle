package mediascope

import (
	"errors"
	"strings"
)

// Clause produces a parameterized SQL AND fragment for an indexed media
// path. Grants are directory prefixes, never arbitrary LIKE patterns:
// "%" and "_" inside a literal folder name must not act as wildcards.
// The column name is a compile-time constant supplied by our indexer code.
func Clause(column string, roots []string) (string, []any, error) {
	if column != "a.path" && column != "f.path" {
		return "", nil, errors.New("invalid_path_column")
	}
	if len(roots) > 256 {
		return "", nil, errors.New("too_many_grants")
	}
	if len(roots) == 0 {
		return " AND 1=0", nil, nil
	}
	for _, root := range roots {
		if root == "." {
			return "", nil, nil
		}
	}
	var parts []string
	var args []any
	for _, root := range roots {
		if root == "" || strings.HasPrefix(root, "/") || strings.Contains(root, "..") && (root == ".." || strings.HasPrefix(root, "../") || strings.Contains(root, "/../")) {
			return "", nil, errors.New("invalid_grant")
		}
		parts = append(parts, "("+column+"=? OR substr("+column+",1,length(?)+1)=?||'/')")
		args = append(args, root, root, root)
	}
	return " AND (" + strings.Join(parts, " OR ") + ")", args, nil
}
