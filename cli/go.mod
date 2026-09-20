module viktorbarzin/infra/cli

go 1.21

require (
	github.com/badoux/checkmail v1.2.1
	github.com/brianvoe/gofakeit/v6 v6.3.0
	github.com/go-git/go-billy/v5 v5.1.0
	github.com/go-git/go-git/v5 v5.3.0
	github.com/golang/glog v0.0.0-20160126235308-23def4e6c14b
	github.com/pkg/errors v0.9.1
	golang.org/x/crypto v0.0.0-20210322153248-0c34fe9e7dc2
)

require (
	github.com/Microsoft/go-winio v0.4.16 // indirect
	github.com/emirpasic/gods v1.12.0 // indirect
	github.com/go-git/gcfg v1.5.0 // indirect
	github.com/imdario/mergo v0.3.12 // indirect
	github.com/jbenet/go-context v0.0.0-20150711004518-d14ea06fba99 // indirect
	github.com/kevinburke/ssh_config v0.0.0-20201106050909-4977a11b4351 // indirect
	github.com/mitchellh/go-homedir v1.1.0 // indirect
	github.com/sergi/go-diff v1.1.0 // indirect
	github.com/xanzy/ssh-agent v0.3.0 // indirect
	golang.org/x/net v0.0.0-20210326060303-6b1517762897 // indirect
	golang.org/x/sys v0.0.0-20210324051608-47abb6519492 // indirect
	gopkg.in/warnings.v0 v0.1.2 // indirect
)

// browser-bridge has no remote yet, so `homelab browser bridge` builds against
// a copy inside this directory. See bridge/README.md for why, and for the
// three lines that delete it once the module is published.
require github.com/ViktorBarzin/browser-bridge v0.0.0

replace github.com/ViktorBarzin/browser-bridge => ./bridge
