// Package config loads and persists ~/.gamechanger/config.yml and the
// session token cache at ~/.gamechanger/session.
//
// Wire-compatible with the Ruby CLI's Gamechanger::Config so a user who
// already ran `gamechanger setup` in Ruby does not need to re-authenticate.
//
// Files:
//   - ~/.gamechanger/config.yml — YAML with email, password, team_id,
//     team_slug, season, device_id. Mode 0600, dir mode 0700.
//   - ~/.gamechanger/session    — Plaintext "token|expires_at_epoch".
//     Mode 0600. Absent or expired ⇒ no cached token.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

const (
	defaultDirName  = ".gamechanger"
	configFileName  = "config.yml"
	sessionFileName = "session"
	defaultTTL      = time.Hour
)

// Config is the in-memory view of ~/.gamechanger/config.yml.
type Config struct {
	Email    string `yaml:"email"`
	Password string `yaml:"password"`
	TeamID   string `yaml:"team_id,omitempty"`
	TeamSlug string `yaml:"team_slug,omitempty"`
	Season   int    `yaml:"season,omitempty"`
	DeviceID string `yaml:"device_id,omitempty"`

	dir         string // resolved config dir for tests
	configPath  string
	sessionPath string
}

// Load reads ~/.gamechanger/config.yml. A missing file returns an empty
// Config with paths populated — Configured() will be false. Other read
// errors are returned wrapped in gcerr.ErrConfig.
func Load() (*Config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, gcerr.Configf("locate home directory: %v", err)
	}
	return LoadFrom(filepath.Join(home, defaultDirName))
}

// LoadFrom reads config from a specific directory (for tests).
func LoadFrom(dir string) (*Config, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, gcerr.Configf("create config dir %s: %v", dir, err)
	}
	cfg := &Config{
		dir:         dir,
		configPath:  filepath.Join(dir, configFileName),
		sessionPath: filepath.Join(dir, sessionFileName),
	}
	data, err := os.ReadFile(cfg.configPath)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		cfg.Season = time.Now().Year()
		return cfg, nil
	case err != nil:
		return nil, gcerr.Configf("read %s: %v", cfg.configPath, err)
	}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, gcerr.Configf("parse %s: %v", cfg.configPath, err)
	}
	if cfg.Season == 0 {
		cfg.Season = time.Now().Year()
	}
	if cfg.DeviceID == "" {
		cfg.DeviceID = generateDeviceID()
	}
	return cfg, nil
}

// Configured reports whether both email and password are set.
func (c *Config) Configured() bool {
	return strings.TrimSpace(c.Email) != "" && strings.TrimSpace(c.Password) != ""
}

// Save validates and writes the config. DeviceID is preserved if already
// set, otherwise generated. Mirrors Ruby Config#save.
func (c *Config) Save() error {
	if strings.TrimSpace(c.Email) == "" {
		return gcerr.Configf("email cannot be empty")
	}
	if strings.TrimSpace(c.Password) == "" {
		return gcerr.Configf("password cannot be empty")
	}
	if c.DeviceID == "" {
		c.DeviceID = generateDeviceID()
	}
	if c.Season == 0 {
		c.Season = time.Now().Year()
	}

	out, err := yaml.Marshal(c)
	if err != nil {
		return gcerr.Configf("marshal config: %v", err)
	}
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		return gcerr.Configf("create config dir %s: %v", c.dir, err)
	}
	if err := writeFile0600(c.configPath, out); err != nil {
		return gcerr.Configf("write %s: %v", c.configPath, err)
	}
	return nil
}

// CachedToken returns the gc-token from the session file, or empty
// string if absent, expired, or malformed. Never errors.
func (c *Config) CachedToken() string {
	data, err := os.ReadFile(c.sessionPath)
	if err != nil {
		return ""
	}
	parts := strings.SplitN(strings.TrimSpace(string(data)), "|", 2)
	if len(parts) == 0 || parts[0] == "" {
		return ""
	}
	if len(parts) == 2 {
		if exp, err := strconv.ParseInt(parts[1], 10, 64); err == nil {
			if time.Now().Unix() > exp {
				return ""
			}
		}
	}
	return parts[0]
}

// CacheToken writes the session file at mode 0600. expiresAt is a Unix
// epoch second. Pass 0 to default to now + 1 hour.
func (c *Config) CacheToken(token string, expiresAt int64) error {
	if expiresAt == 0 {
		expiresAt = time.Now().Add(defaultTTL).Unix()
	}
	payload := token + "|" + strconv.FormatInt(expiresAt, 10)
	if err := writeFile0600(c.sessionPath, []byte(payload)); err != nil {
		return gcerr.Configf("write session: %v", err)
	}
	return nil
}

// ClearToken removes the session file. Idempotent.
func (c *Config) ClearToken() error {
	err := os.Remove(c.sessionPath)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return gcerr.Configf("remove session: %v", err)
	}
	return nil
}

// Dir returns the resolved config directory.
func (c *Config) Dir() string { return c.dir }

func generateDeviceID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		// Cryptographic rand failure on a modern OS is unrecoverable; let
		// the caller surface it via the next Save instead of panicking.
		return ""
	}
	return hex.EncodeToString(buf)
}

func writeFile0600(path string, data []byte) error {
	// O_CREAT|O_TRUNC|O_WRONLY with mode 0600 — matches the Ruby version's
	// File.open(..., File::WRONLY|CREAT|TRUNC, 0o600).
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	// Fix mode in case umask masked us on first create.
	return os.Chmod(path, 0o600)
}
