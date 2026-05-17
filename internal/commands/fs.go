package commands

import "os"

// readFile is a tiny wrapper around os.ReadFile so auth.go can avoid
// importing os just to read one file.
func readFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}
