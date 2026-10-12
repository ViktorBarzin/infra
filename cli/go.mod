module viktorbarzin/infra/cli

go 1.26.0

require (
	github.com/badoux/checkmail v1.2.1
	github.com/brianvoe/gofakeit/v6 v6.3.0
	github.com/go-git/go-billy/v5 v5.9.2
	github.com/go-git/go-git/v5 v5.19.3
	github.com/golang/glog v0.0.0-20160126235308-23def4e6c14b
	github.com/pkg/errors v0.9.1
	golang.org/x/crypto v0.58.0
)

require (
	dario.cat/mergo v1.0.0 // indirect
	github.com/Microsoft/go-winio v0.6.2 // indirect
	github.com/ProtonMail/go-crypto v1.1.6 // indirect
	github.com/cloudflare/circl v1.6.3 // indirect
	github.com/cyphar/filepath-securejoin v0.6.1 // indirect
	github.com/emirpasic/gods v1.18.1 // indirect
	github.com/go-git/gcfg v1.5.1-0.20230307220236-3a3c6141e376 // indirect
	github.com/golang/groupcache v0.0.0-20241129210726-2c02b8208cf8 // indirect
	github.com/jbenet/go-context v0.0.0-20150711004518-d14ea06fba99 // indirect
	github.com/kevinburke/ssh_config v1.2.0 // indirect
	github.com/pjbgf/sha1cd v0.7.0 // indirect
	github.com/sergi/go-diff v1.3.2-0.20230802210424-5b0b94c5c0d3 // indirect
	github.com/skeema/knownhosts v1.3.1 // indirect
	github.com/xanzy/ssh-agent v0.3.3 // indirect
	golang.org/x/net v0.61.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	gopkg.in/warnings.v0 v0.1.2 // indirect
)

// browser-bridge has no remote yet, so `homelab browser bridge` builds against
// a copy inside this directory. See bridge/README.md for why, and for the
// three lines that delete it once the module is published.
require github.com/ViktorBarzin/browser-bridge v0.0.0

replace github.com/ViktorBarzin/browser-bridge => ./bridge
