package client

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Environment overrides. The verb reads these itself when it builds a client,
// so nothing in this package reaches for the environment on its own except
// the helpers below.
const (
	// EnvToken carries a CLI token, for a test or a headless agent job that
	// has no file to read.
	EnvToken = "BROWSER_BRIDGE_TOKEN"
	// EnvServer overrides the server, for development.
	EnvServer = "BROWSER_BRIDGE_URL"
	// EnvBrowser names the default browser, between the --browser flag and
	// the user's default on the server.
	EnvBrowser = "BROWSER_BRIDGE_BROWSER"
)

// DefaultBaseURL is the deployed server.
const DefaultBaseURL = "https://browser-bridge.viktorbarzin.me"

func configHome() string {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return v
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".config")
	}
	return ".config"
}

// TokenPath is where the provisioner writes this OS user's CLI token.
func TokenPath() string {
	return filepath.Join(configHome(), "browser-bridge", "token")
}

// TokenFromEnvOrFile reads the CLI token, preferring the environment so a
// test or a headless job can inject one without writing a file.
//
// The file must not be readable by anyone else. This is a shared box, and a
// token that another OS user can read drives that user's Chrome.
func TokenFromEnvOrFile() (string, error) {
	if v := strings.TrimSpace(os.Getenv(EnvToken)); v != "" {
		return v, nil
	}

	path := TokenPath()
	info, err := os.Stat(path)
	if err != nil {
		return "", &UsageError{
			Message: fmt.Sprintf("no browser-bridge token at %s", path),
			Hint:    fmt.Sprintf("the provisioner writes one per OS user at mode 0600, or set %s", EnvToken),
		}
	}
	if mode := info.Mode().Perm(); mode&0o077 != 0 {
		return "", &UsageError{
			Message: fmt.Sprintf("the token at %s is mode %04o, which other users on this box can read", path, mode),
			Hint:    fmt.Sprintf("chmod 600 %s", path),
		}
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		return "", &UsageError{Message: fmt.Sprintf("cannot read %s, %v", path, err)}
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", &UsageError{Message: fmt.Sprintf("the token at %s is empty", path)}
	}
	return token, nil
}

// BaseURLFromEnv gives the server to talk to, the deployed one unless
// EnvServer names another.
func BaseURLFromEnv() string {
	if v := strings.TrimSpace(os.Getenv(EnvServer)); v != "" {
		return v
	}
	return DefaultBaseURL
}

// BrowserFromEnv gives the browser named by EnvBrowser, or an empty string.
// The resolution order is the --browser flag, then this, then the user's
// default on the server, and the caller owns the first two.
func BrowserFromEnv() string {
	return strings.TrimSpace(os.Getenv(EnvBrowser))
}
