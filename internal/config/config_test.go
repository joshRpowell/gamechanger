package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

func newTempConfigDir(t *testing.T) string {
	t.Helper()
	return t.TempDir()
}

func TestLoadFrom_MissingFile_SetsDefaults(t *testing.T) {
	dir := newTempConfigDir(t)
	cfg, err := LoadFrom(dir)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	if cfg.Configured() {
		t.Fatalf("Configured() = true on empty config")
	}
	if cfg.Season != time.Now().Year() {
		t.Fatalf("Season = %d; want current year %d", cfg.Season, time.Now().Year())
	}
}

func TestSaveAndReload(t *testing.T) {
	dir := newTempConfigDir(t)
	cfg, err := LoadFrom(dir)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	cfg.Email = "test@example.com"
	cfg.Password = "secret"
	cfg.TeamID = "uuid-1"
	cfg.TeamSlug = "slug1"
	if err := cfg.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if cfg.DeviceID == "" {
		t.Fatalf("DeviceID not auto-generated on save")
	}

	info, err := os.Stat(filepath.Join(dir, configFileName))
	if err != nil {
		t.Fatalf("stat config: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("config mode = %v; want 0600", info.Mode().Perm())
	}

	cfg2, err := LoadFrom(dir)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if cfg2.Email != "test@example.com" || cfg2.Password != "secret" ||
		cfg2.TeamID != "uuid-1" || cfg2.TeamSlug != "slug1" ||
		cfg2.DeviceID != cfg.DeviceID {
		t.Fatalf("reload mismatch: %+v vs %+v", cfg2, cfg)
	}
}

func TestSave_EmptyEmailReturnsConfigError(t *testing.T) {
	cfg, _ := LoadFrom(newTempConfigDir(t))
	cfg.Password = "x"
	err := cfg.Save()
	if err == nil || !errors.Is(err, gcerr.ErrConfig) {
		t.Fatalf("Save with empty email = %v; want gcerr.ErrConfig", err)
	}
}

func TestSave_EmptyPasswordReturnsConfigError(t *testing.T) {
	cfg, _ := LoadFrom(newTempConfigDir(t))
	cfg.Email = "a@b"
	err := cfg.Save()
	if err == nil || !errors.Is(err, gcerr.ErrConfig) {
		t.Fatalf("Save with empty password = %v; want gcerr.ErrConfig", err)
	}
}

func TestCacheTokenRoundTrip(t *testing.T) {
	cfg, _ := LoadFrom(newTempConfigDir(t))
	if err := cfg.CacheToken("abc.def.ghi", time.Now().Add(time.Hour).Unix()); err != nil {
		t.Fatalf("CacheToken: %v", err)
	}
	got := cfg.CachedToken()
	if got != "abc.def.ghi" {
		t.Fatalf("CachedToken = %q; want %q", got, "abc.def.ghi")
	}

	info, err := os.Stat(cfg.sessionPath)
	if err != nil {
		t.Fatalf("stat session: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("session mode = %v; want 0600", info.Mode().Perm())
	}
}

func TestCachedToken_ExpiredReturnsEmpty(t *testing.T) {
	cfg, _ := LoadFrom(newTempConfigDir(t))
	// Expired in the past
	if err := cfg.CacheToken("token", time.Now().Add(-time.Hour).Unix()); err != nil {
		t.Fatalf("CacheToken: %v", err)
	}
	if got := cfg.CachedToken(); got != "" {
		t.Fatalf("CachedToken on expired = %q; want empty", got)
	}
}

func TestCachedToken_MissingFileReturnsEmpty(t *testing.T) {
	cfg, _ := LoadFrom(newTempConfigDir(t))
	if got := cfg.CachedToken(); got != "" {
		t.Fatalf("CachedToken with no file = %q; want empty", got)
	}
}

func TestClearTokenIdempotent(t *testing.T) {
	cfg, _ := LoadFrom(newTempConfigDir(t))
	// Twice in a row, both must succeed without error.
	if err := cfg.ClearToken(); err != nil {
		t.Fatalf("first ClearToken: %v", err)
	}
	_ = cfg.CacheToken("t", time.Now().Add(time.Hour).Unix())
	if err := cfg.ClearToken(); err != nil {
		t.Fatalf("after CacheToken: %v", err)
	}
	if _, err := os.Stat(cfg.sessionPath); !os.IsNotExist(err) {
		t.Fatalf("session file still present after ClearToken: %v", err)
	}
}

func TestSavePreservesDeviceIDAcrossLoads(t *testing.T) {
	dir := newTempConfigDir(t)
	cfg, _ := LoadFrom(dir)
	cfg.Email = "e"
	cfg.Password = "p"
	_ = cfg.Save()
	firstID := cfg.DeviceID

	cfg2, _ := LoadFrom(dir)
	if cfg2.DeviceID != firstID {
		t.Fatalf("DeviceID changed on reload: %q -> %q", firstID, cfg2.DeviceID)
	}

	cfg2.Email = "e2"
	_ = cfg2.Save()
	if cfg2.DeviceID != firstID {
		t.Fatalf("Save regenerated DeviceID: %q -> %q", firstID, cfg2.DeviceID)
	}
}
