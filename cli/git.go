package main

import (
	"os"

	"github.com/go-git/go-billy/v5"
	"github.com/go-git/go-billy/v5/memfs"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/transport/http"
	memory "github.com/go-git/go-git/v5/storage/memory"
	"github.com/golang/glog"
	"github.com/pkg/errors"
)

const (
	repository = "https://github.com/ViktorBarzin/infra"
)

var (
	gitUser  = os.Getenv("GIT_USER")
	gitToken = os.Getenv("GIT_TOKEN")
)

type GitFS struct {
	repo *git.Repository
	fs   *billy.Filesystem
	auth *http.BasicAuth
}

func NewGitFS(repoURL string) (*GitFS, error) {
	glog.Infof("initializing new git fs from repo url: %s", repoURL)
	auth := &http.BasicAuth{
		Username: gitUser,
		Password: gitToken,
	}
	storer := memory.NewStorage()
	fs := memfs.New()

	r, err := git.Clone(storer, fs, &git.CloneOptions{
		URL:  repository,
		Auth: auth,
	})
	if err != nil {
		return nil, errors.Wrapf(err, "failed to clone repo from repo url '%s'", repoURL)
	}
	return &GitFS{repo: r, fs: &fs, auth: auth}, nil
}

func (g *GitFS) Push() error {
	return g.repo.Push(&git.PushOptions{Auth: g.auth})
}
