package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// `homelab deploy <app>` builds an app's landed master (or --sha) on the devvm
// and puts it live the way its GitHub Actions workflows would: the server
// image to ghcr plus the Woodpecker deploy, the TV app to ghcr plus the
// publish pipeline. It exists so anyone who can land a change can also get it
// live while Actions cannot build (billing, infra#152), with one credential
// in Vault that every permitted account reads (infra#153).
//
// It always builds from a fresh clone in a temporary directory, never from
// anyone's checkout or worktree, so the commit count (the TV versionCode) is
// master's own. What CI already built or what is already live is skipped.

const defaultReleaseLock = "/run/lock/f1-stream-release.lock"

func deployRelease(args []string) error {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.Println(deployReleaseHelp)
		return nil
	}
	o, err := parseReleaseArgs(args)
	if err != nil {
		return err
	}
	r := &releaseRun{spec: releaseSpecs[o.App](), opts: o, out: os.Stdout,
		site: &http.Client{Timeout: 60 * time.Second}}
	defer r.cleanup()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		if _, ok := <-sig; ok {
			fmt.Fprintln(os.Stderr, "homelab: interrupted; cleaning up")
			r.cleanup()
			os.Exit(130)
		}
	}()
	defer signal.Stop(sig)
	return r.run()
}

const deployReleaseHelp = `homelab deploy <app> [--server] [--tv] [--sha SHA] [--check]

Build an app's landed master on this box and put it live, the way its GitHub
Actions workflows would. Apps: f1-stream.

  --check    work out and print what would happen; build and push nothing
  --server   only the server image (ghcr :<sha8>, then the Woodpecker deploy)
  --tv       only the TV app (ghcr f1-stream-tv:<versionCode>, then publish-tv)
  --sha SHA  a commit on master other than its tip

Without --server or --tv each half runs only when a path it is built from
changed since what is live (the workflows' own path filters). Whatever is
already live, or already built on ghcr, is skipped. A TV versionCode that is
not above the one televisions are offered is refused. One release runs at a
time on the devvm (` + defaultReleaseLock + `).

Credentials come from Vault secret/ci/f1-stream-release; tokens go to docker
and Woodpecker on stdin or in headers, never on a command line.`

type releaseCreds struct {
	GHCRUser, GHCRToken, WoodpeckerToken string
}

func readReleaseCreds(path string) (releaseCreds, error) {
	cmd := exec.Command("vault", "kv", "get", "-format=json", path)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if i := strings.Index(msg, "\n"); i >= 0 {
			msg = msg[:i]
		}
		return releaseCreds{}, fmt.Errorf("cannot read Vault %s (%s).\n"+
			"Each account that may release is granted read on that path in infra stacks/vault/main.tf.\n"+
			"If yours is not, file an infra issue (the file-issue skill) asking for it", path, msg)
	}
	var v struct {
		Data struct {
			Data map[string]string `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &v); err != nil {
		return releaseCreds{}, fmt.Errorf("Vault %s: unreadable answer", path)
	}
	c := releaseCreds{v.Data.Data["ghcr_username"], v.Data.Data["ghcr_token"], v.Data.Data["woodpecker_token"]}
	if c.GHCRUser == "" || c.GHCRToken == "" || c.WoodpeckerToken == "" {
		return c, fmt.Errorf("Vault %s lacks one of ghcr_username, ghcr_token, woodpecker_token", path)
	}
	return c, nil
}

type releaseRun struct {
	spec releaseSpec
	opts releaseOpts
	out  io.Writer
	site *http.Client

	creds     releaseCreds
	reg       *registryClient
	wp        *wpClient
	work      string // temporary directory holding src/ and docker/
	src       string
	dockerCfg string
	target    string // full sha being released
	masterTip string
	sha8      string
	version   releaseVersion

	liveServer string
	liveTV     int
	liveTVSHA  string

	server, tv releaseDecision
	serverOn   bool
	tvOn       bool

	mu       sync.Mutex
	cleanups []func()
}

func (r *releaseRun) say(format string, a ...interface{}) {
	fmt.Fprintf(r.out, "homelab: "+format+"\n", a...)
}

func (r *releaseRun) onCleanup(f func()) {
	r.mu.Lock()
	r.cleanups = append(r.cleanups, f)
	r.mu.Unlock()
}

// cleanup runs the registered cleanups once, newest first.
func (r *releaseRun) cleanup() {
	r.mu.Lock()
	fs := r.cleanups
	r.cleanups = nil
	r.mu.Unlock()
	for i := len(fs) - 1; i >= 0; i-- {
		fs[i]()
	}
}

func (r *releaseRun) run() error {
	var err error
	if r.creds, err = readReleaseCreds(r.spec.VaultPath); err != nil {
		return err
	}
	r.reg = &registryClient{base: "https://ghcr.io", user: r.creds.GHCRUser, token: r.creds.GHCRToken,
		http: &http.Client{Timeout: 30 * time.Second}}
	r.wp = newWPClientWithToken(r.creds.WoodpeckerToken)

	if !r.opts.Check {
		lockPath := firstEnv("HOMELAB_RELEASE_LOCK")
		if lockPath == "" {
			lockPath = defaultReleaseLock
		}
		note := fmt.Sprintf("%s (pid %d) releasing %s since %s", currentUser(), os.Getpid(), r.spec.App,
			time.Now().UTC().Format("15:04 UTC"))
		unlock, err := acquireReleaseLock(lockPath, 90*time.Minute, note, r.out)
		if err != nil {
			return err
		}
		r.onCleanup(unlock)
	}

	if err := r.checkout(); err != nil {
		return err
	}
	if err := r.plan(); err != nil {
		return err
	}
	if r.opts.Check {
		r.say("--check: nothing built or pushed")
		return nil
	}
	if !r.server.Action.runs() && !r.tv.Action.runs() {
		r.say("nothing to release")
		return nil
	}
	if err := r.claimPresence(); err != nil {
		return err
	}
	if err := r.dockerLogin(); err != nil {
		return err
	}
	if r.server.Action.runs() {
		if err := r.releaseServer(); err != nil {
			return fmt.Errorf("server: %w", err)
		}
	}
	if r.tv.Action.runs() {
		if err := r.releaseTV(); err != nil {
			return fmt.Errorf("TV app: %w", err)
		}
	}
	r.say("done")
	return nil
}

func (r *releaseRun) git(args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", r.src}, args...)...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %v %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(string(out)), nil
}

// checkout clones the app into a fresh temporary directory and checks out the
// commit being released.
func (r *releaseRun) checkout() error {
	work, err := os.MkdirTemp("/var/tmp", "homelab-release-"+r.spec.App+"-")
	if err != nil {
		return err
	}
	r.work = work
	r.onCleanup(func() { removeWorkDir(work) })
	r.src = filepath.Join(work, "src")
	cloneArgs := []string{"clone", "--quiet", "--no-checkout"}
	if home, err := os.UserHomeDir(); err == nil {
		local := filepath.Join(home, r.spec.LocalClone)
		if st, err := os.Stat(filepath.Join(local, ".git")); err == nil && st.IsDir() {
			// Borrow objects from the user's clone to save the download, then
			// copy them, so nothing here depends on that clone afterwards.
			cloneArgs = append(cloneArgs, "--reference-if-able", local, "--dissociate")
		}
	}
	cloneArgs = append(cloneArgs, r.spec.GitURL, r.src)
	cmd := exec.Command("git", cloneArgs...)
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git clone %s: %w", r.spec.GitURL, err)
	}
	if r.masterTip, err = r.git("rev-parse", "origin/master"); err != nil {
		return err
	}
	r.target = r.masterTip
	if r.opts.SHA != "" {
		if r.target, err = r.git("rev-parse", "--verify", r.opts.SHA+"^{commit}"); err != nil {
			return fmt.Errorf("--sha %s is not a commit in %s", r.opts.SHA, r.spec.GitURL)
		}
		if _, err := r.git("merge-base", "--is-ancestor", r.target, "origin/master"); err != nil {
			return fmt.Errorf("--sha %s is not on master; land it first (the versionCode is master's commit count)", r.opts.SHA)
		}
	}
	if _, err := r.git("checkout", "--quiet", "--detach", r.target); err != nil {
		return err
	}
	r.sha8 = r.target[:8]
	countS, err := r.git("rev-list", "--count", r.target)
	if err != nil {
		return err
	}
	count, _ := strconv.Atoi(countS)
	tag, _ := r.git("describe", "--tags", "--abbrev=0", r.target)
	r.version = releaseVersionFor(r.spec.VersionFloor, count, tag)
	return nil
}

func removeWorkDir(dir string) {
	if os.RemoveAll(dir) == nil {
		return
	}
	// The Gradle container runs as root, and a file it left behind is not ours
	// to delete; the same image removes it.
	_ = exec.Command("docker", "run", "--rm", "-v", dir+":/w", "eclipse-temurin:17-jdk",
		"sh", "-c", "rm -rf /w/* /w/.[!.]*").Run()
	_ = os.RemoveAll(dir)
}

func (r *releaseRun) getJSON(path string, v interface{}) error {
	resp, err := r.site.Get(r.spec.Site + path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s%s -> HTTP %d", r.spec.Site, path, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

func (r *releaseRun) liveVersion() (string, error) {
	var v struct {
		Commit string `json:"commit"`
	}
	err := r.getJSON("/api/version", &v)
	return v.Commit, err
}

func (r *releaseRun) liveTVLatest() (int, string, error) {
	var v struct {
		VersionCode int    `json:"versionCode"`
		SHA256      string `json:"sha256"`
	}
	err := r.getJSON("/api/app/latest", &v)
	return v.VersionCode, v.SHA256, err
}

// relation places commit relative to the target, both on master.
func (r *releaseRun) relation(commit string) (liveRelation, string) {
	if commit == "" {
		return liveUnknown, ""
	}
	full, err := r.git("rev-parse", "--verify", "--quiet", commit+"^{commit}")
	if err != nil {
		return liveUnknown, ""
	}
	if full == r.target {
		return liveSame, full
	}
	if _, err := r.git("merge-base", "--is-ancestor", full, r.target); err == nil {
		return liveOlder, full
	}
	if _, err := r.git("merge-base", "--is-ancestor", r.target, full); err == nil {
		return liveNewer, full
	}
	return liveUnknown, full
}

func (r *releaseRun) changedSince(from string) ([]string, error) {
	out, err := r.git("diff", "--name-only", from, r.target)
	if err != nil {
		return nil, err
	}
	if out == "" {
		return nil, nil
	}
	return strings.Split(out, "\n"), nil
}

func (r *releaseRun) plan() error {
	r.serverOn = r.opts.auto() || r.opts.Server
	r.tvOn = r.opts.auto() || r.opts.TV
	tipNote := "master's tip"
	if r.target != r.masterTip {
		tipNote = "on master, tip is " + r.masterTip[:8]
	}
	r.say("%s %s (%s): versionCode %d, versionName %s", r.spec.App, r.sha8, tipNote, r.version.Code, r.version.Name)

	r.server = releaseDecision{actionNotAsked, "--tv only"}
	if r.serverOn {
		live, err := r.liveVersion()
		if err != nil {
			r.say("could not read %s/api/version (%v); treating the live commit as unknown", r.spec.Site, err)
		}
		r.liveServer = live
		rel, full := r.relation(live)
		f := serverFacts{Auto: r.opts.auto(), Live: rel, LiveCommit: live}
		if rel == liveOlder {
			paths, err := r.changedSince(full)
			if err != nil {
				return err
			}
			f.Changed, _ = r.spec.classify(paths)
		}
		if f.Live != liveSame && f.Live != liveNewer {
			_, ok, err := r.reg.manifest(r.spec.Image, r.sha8)
			if err != nil {
				return err
			}
			f.OnRegistry = ok
		}
		r.server = decideServer(f)
	}
	r.say("server image %s:%s: %s (%s)", r.spec.Image, r.sha8, r.server.Action, r.server.Reason)

	r.tv = releaseDecision{actionNotAsked, "--server only"}
	if r.tvOn {
		code, sum, err := r.liveTVLatest()
		f := tvFacts{Auto: r.opts.auto(), Code: r.version.Code, LiveCode: code, LiveUnknown: err != nil || code == 0}
		r.liveTV, r.liveTVSHA = code, sum
		if !f.LiveUnknown && f.Code > code {
			if sha, ok := r.commitForTVCode(code); ok {
				paths, err := r.changedSince(sha)
				if err != nil {
					return err
				}
				_, f.Changed = r.spec.classify(paths)
				f.ChangeKnown = true
			}
			_, ok, err := r.reg.manifest(r.spec.TVRepo, strconv.Itoa(r.version.Code))
			if err != nil {
				return err
			}
			f.OnRegistry = ok
		}
		r.tv = decideTV(f)
	}
	r.say("TV app %s:%d: %s (%s)", r.spec.TVRepo, r.version.Code, r.tv.Action, r.tv.Reason)

	if r.server.Action == actionRefuse || r.tv.Action == actionRefuse {
		return fmt.Errorf("refused; nothing was built or pushed")
	}
	return nil
}

// commitForTVCode finds the master tip whose commit count gives code.
func (r *releaseRun) commitForTVCode(code int) (string, bool) {
	out, err := r.git("rev-list", "--first-parent", "--max-count=2000", r.target)
	if err != nil {
		return "", false
	}
	count := func(sha string) (int, error) {
		s, err := r.git("rev-list", "--count", sha)
		if err != nil {
			return 0, err
		}
		return strconv.Atoi(s)
	}
	return commitWithCount(strings.Split(out, "\n"), count, code-r.spec.VersionFloor)
}

// claimPresence puts service:<app> on the presence board for the release and
// takes it off again at the end, unless this session already held it.
func (r *releaseRun) claimPresence() error {
	bin, err := exec.LookPath("presence")
	if err != nil {
		if _, e := os.Stat(presenceScript()); e != nil {
			r.say("no presence CLI on this box; not claiming service:%s", r.spec.App)
			return nil
		}
		bin = presenceScript()
	}
	label := "service:" + r.spec.App
	held := false
	if out, err := exec.Command(bin, "--json", "list", "--mine").Output(); err == nil {
		var claims []struct {
			Label string `json:"resource_label"`
		}
		if json.Unmarshal(out, &claims) == nil {
			for _, c := range claims {
				held = held || c.Label == label
			}
		}
	}
	out, _ := exec.Command(bin, "claim", label, "--ttl", "5400",
		"--purpose", fmt.Sprintf("homelab deploy %s %s: build and put live by hand", r.spec.App, r.sha8)).CombinedOutput()
	if strings.Contains(string(out), "ALSO CLAIMED BY") {
		if !held {
			_ = exec.Command(bin, "release", label).Run()
		}
		return fmt.Errorf("another session holds %s on the presence board:\n%s\nWait until `presence peek %s` shows no other claim, then run this again",
			label, strings.TrimSpace(string(out)), label)
	}
	if !held {
		r.onCleanup(func() { _ = exec.Command(bin, "release", label).Run() })
	}
	return nil
}

// dockerLogin logs a throwaway docker config into ghcr, token on stdin, so
// the build and the oras pushes never touch the caller's ~/.docker.
func (r *releaseRun) dockerLogin() error {
	r.dockerCfg = filepath.Join(r.work, "docker")
	if err := os.MkdirAll(r.dockerCfg, 0o700); err != nil {
		return err
	}
	cmd := exec.Command("docker", "--config", r.dockerCfg, "login", "ghcr.io", "-u", r.creds.GHCRUser, "--password-stdin")
	cmd.Stdin = strings.NewReader(r.creds.GHCRToken)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("docker login ghcr.io with the release credential: %v %s", err, strings.TrimSpace(string(out)))
	}
	// The oras container reads this file as root; the directory stays 0700.
	return os.Chmod(filepath.Join(r.dockerCfg, "config.json"), 0o644)
}

func (r *releaseRun) stream(dir string, env []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdout = r.out
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), env...)
	return cmd.Run()
}

func (r *releaseRun) releaseServer() error {
	if r.server.Action == actionBuild {
		args := []string{"buildx", "build", "--platform", "linux/amd64", "--provenance=false", "--push",
			"--build-arg", "GIT_COMMIT=" + r.sha8,
			"--build-arg", "APP_BUILD=" + strconv.Itoa(r.version.Code),
			"--build-arg", "APP_VERSION=" + r.version.Image,
			"-t", r.spec.Image + ":" + r.sha8}
		// :latest rides master's tip only, as in build.yml.
		if r.target == r.masterTip {
			args = append(args, "-t", r.spec.Image+":latest")
		}
		// The web chunks of earlier releases ride along from :latest (ADR-0029).
		if _, ok, err := r.reg.manifest(r.spec.Image, "latest"); err == nil && ok {
			args = append(args, "--build-context", "previous=docker-image://"+r.spec.Image+":latest")
		} else {
			r.say("no %s:latest to carry web chunks from", r.spec.Image)
		}
		args = append(args, r.src)
		r.say("building %s:%s", r.spec.Image, r.sha8)
		if err := r.stream(r.src, []string{"DOCKER_CONFIG=" + r.dockerCfg}, "docker", args...); err != nil {
			return fmt.Errorf("docker buildx build: %w", err)
		}
	}
	vars := map[string]string{"IMAGE_TAG": r.sha8, "IMAGE_NAME": r.spec.Image}
	if err := r.runPipeline(vars, 40*time.Minute, true); err != nil {
		return err
	}
	return r.confirmServer()
}

// runPipeline starts a manual pipeline and waits for it. A deploy whose order
// step failed most likely ran before the GitHub mirror had the commit (the
// step refuses a commit it cannot place on master), so it is started again.
func (r *releaseRun) runPipeline(vars map[string]string, timeout time.Duration, retryOrder bool) error {
	for attempt := 1; ; attempt++ {
		n, err := r.wp.startManualPipeline(r.spec.WoodpeckerRepo, vars)
		if err != nil {
			return err
		}
		r.say("started Woodpecker repo %d pipeline %d (%v)", r.spec.WoodpeckerRepo, n, vars)
		p, err := r.wp.waitPipeline(r.spec.WoodpeckerRepo, n, timeout, r.out)
		if err != nil {
			return err
		}
		if p.Status == "success" {
			return nil
		}
		failed := p.failedSteps()
		if retryOrder && attempt < 6 && len(failed) == 1 && failed[0] == "order" {
			r.say("the deploy could not place %s on master yet (the GitHub mirror may be behind); starting it again in 30s", r.sha8)
			time.Sleep(30 * time.Second)
			continue
		}
		return fmt.Errorf("Woodpecker repo %d pipeline %d ended %s (failed steps: %v); see https://ci.viktorbarzin.me/repos/%d/pipeline/%d",
			r.spec.WoodpeckerRepo, n, p.Status, failed, r.spec.WoodpeckerRepo, n)
	}
}

func (r *releaseRun) confirmServer() error {
	img, _ := kubectlCapture(r.spec.Namespace, "get", "deploy", r.spec.EdgeDeployment,
		"-o", "jsonpath={.spec.template.spec.containers[*].image}")
	if strings.Contains(img, ":"+r.sha8) {
		if err := waitDeployImage(r.spec.Namespace, r.spec.EdgeDeployment, r.sha8, 10*time.Minute); err != nil {
			return err
		}
	}
	deadline := time.Now().Add(5 * time.Minute)
	for {
		live, err := r.liveVersion()
		if err == nil {
			rel, _ := r.relation(live)
			switch rel {
			case liveSame:
				r.say("%s/api/version reports commit %s", r.spec.Site, live)
				return nil
			case liveNewer:
				r.say("superseded: %s/api/version reports %s, which already contains %s", r.spec.Site, live, r.sha8)
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("the deploy finished but %s/api/version still reports %q, not %s", r.spec.Site, live, r.sha8)
		}
		time.Sleep(5 * time.Second)
	}
}

func (r *releaseRun) releaseTV() error {
	code := r.version.Code
	tag := strconv.Itoa(code)
	var expect string
	if r.tv.Action == actionBuild {
		sum, err := r.buildTV()
		if err != nil {
			return err
		}
		expect = sum
		// Master and the televisions may have moved during a 10-minute build;
		// check again right before anything leaves this machine.
		if live, _, err := r.liveTVLatest(); err != nil || live >= code {
			return fmt.Errorf("televisions are now offered %d (err %v); %d is not above it, so this build is not published", live, err, code)
		}
		if _, ok, err := r.reg.manifest(r.spec.TVRepo, tag); err != nil || ok {
			return fmt.Errorf("%s:%s appeared on ghcr during the build (err %v); someone else is publishing it", r.spec.TVRepo, tag, err)
		}
		if err := r.orasPush(); err != nil {
			return err
		}
	} else {
		m, ok, err := r.reg.manifest(r.spec.TVRepo, tag)
		if err != nil || !ok {
			return fmt.Errorf("%s:%s is not readable on ghcr (err %v)", r.spec.TVRepo, tag, err)
		}
		expect = m.layerDigest("app-release.apk")
	}
	if err := r.runPipeline(map[string]string{"PIPELINE": "publish-tv", "TV_VERSION": tag}, 20*time.Minute, false); err != nil {
		return err
	}
	return r.confirmTV(code, expect)
}

func (r *releaseRun) apkOut() string {
	return filepath.Join(r.src, "android", "app", "build", "outputs", "apk", "release")
}

// buildTV runs the repo's own build script (it takes the shared APK build
// lock itself), then checks what came out, and returns the APK's sha256.
func (r *releaseRun) buildTV() (string, error) {
	code := r.version.Code
	r.say("building TV app versionCode %d (%s)", code, r.version.Name)
	env := []string{"BUILD_APK_LOCKED=", "BUILD_LOCK="}
	if err := r.stream(r.src, env, "android/scripts/build-apk.sh", "testDebugUnitTest", "assembleRelease",
		"-PtvVersionName="+r.version.Name, "-PtvVersionCode="+strconv.Itoa(code)); err != nil {
		return "", fmt.Errorf("android/scripts/build-apk.sh: %w", err)
	}
	out := r.apkOut()
	meta, err := os.ReadFile(filepath.Join(out, "output-metadata.json"))
	if err != nil {
		return "", err
	}
	metaCode, file, err := parseOutputMetadata(meta)
	if err != nil {
		return "", err
	}
	if metaCode != code || file != "app-release.apk" {
		return "", fmt.Errorf("output-metadata.json says %s versionCode %d, not app-release.apk %d", file, metaCode, code)
	}
	apk := filepath.Join(out, "app-release.apk")
	if err := apkHasBaselineProfile(apk); err != nil {
		return "", err
	}
	sdk := firstEnv("SDK_VOL")
	if sdk == "" {
		sdk = "portalframe-android-sdk"
	}
	tool := func(args ...string) (string, error) {
		full := append([]string{"run", "--rm", "-v", sdk + ":/sdk:ro", "-v", out + ":/apk:ro", "eclipse-temurin:17-jdk"}, args...)
		b, err := exec.Command("docker", full...).Output()
		return string(b), err
	}
	certs, err := tool("/sdk/build-tools/34.0.0/apksigner", "verify", "--print-certs", "/apk/app-release.apk")
	if err != nil {
		return "", fmt.Errorf("apksigner verify: %w", err)
	}
	if got := parseSignerDigest(certs); got != r.spec.Signer {
		return "", fmt.Errorf("the APK is signed by %q, not the shared key %s; no television would install it", got, r.spec.Signer)
	}
	badging, err := tool("/sdk/build-tools/34.0.0/aapt", "dump", "badging", "/apk/app-release.apk")
	if err != nil {
		return "", fmt.Errorf("aapt dump badging: %w", err)
	}
	if got, debuggable := parseBadging(badging); got != code || debuggable {
		return "", fmt.Errorf("the APK carries versionCode %d (debuggable %v); want %d, not debuggable", got, debuggable, code)
	}
	sum, err := fileSHA256(apk)
	if err != nil {
		return "", err
	}
	r.say("APK checked: versionCode %d, signer %s..., baseline profile present, sha256 %s", code, r.spec.Signer[:12], sum)
	return sum, nil
}

func apkHasBaselineProfile(apk string) error {
	z, err := zip.OpenReader(apk)
	if err != nil {
		return fmt.Errorf("open %s: %w", apk, err)
	}
	defer z.Close()
	for _, f := range z.File {
		if f.Name == "assets/dexopt/baseline.prof" {
			return nil
		}
	}
	return fmt.Errorf("the APK carries no assets/dexopt/baseline.prof")
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

const orasImage = "ghcr.io/oras-project/oras:v1.2.0"

// orasPush pushes the APK and its metadata, and the R8 mapping, exactly as
// .github/workflows/android.yml does.
func (r *releaseRun) orasPush() error {
	tag := strconv.Itoa(r.version.Code)
	cfg := filepath.Join(r.dockerCfg, "config.json") + ":/root/.docker/config.json:ro"
	push := func(dir string, extra ...string) error {
		args := append([]string{"run", "--rm", "-v", dir + ":/w:ro", "-w", "/w", "-v", cfg, orasImage, "push"}, extra...)
		return r.stream("", nil, "docker", args...)
	}
	r.say("pushing %s:%s", r.spec.TVRepo, tag)
	if err := push(r.apkOut(), r.spec.TVRepo+":"+tag, "--artifact-type", "application/vnd.viktorbarzin.f1tv.build",
		"app-release.apk:application/vnd.android.package-archive", "output-metadata.json:application/json"); err != nil {
		return fmt.Errorf("oras push: %w", err)
	}
	mapping := filepath.Join(r.src, "android", "app", "build", "outputs", "mapping", "release")
	if _, err := os.Stat(filepath.Join(mapping, "mapping.txt")); err == nil {
		if err := push(mapping, r.spec.TVRepo+":"+tag+"-mapping", "--artifact-type", "application/vnd.viktorbarzin.f1tv.mapping",
			"mapping.txt:text/plain"); err != nil {
			r.say("the R8 mapping did not push (%v); the release goes ahead without it", err)
		}
	}
	return nil
}

// confirmTV waits until /api/app/latest offers code and the APK the site
// serves is the one published. The download briefly served an older APK
// than /api/app/latest described on 2026-10-30, so a mismatch is retried.
func (r *releaseRun) confirmTV(code int, expect string) error {
	deadline := time.Now().Add(5 * time.Minute)
	var why string
	for {
		live, sum, err := r.liveTVLatest()
		switch {
		case err != nil:
			why = err.Error()
		case live > code:
			r.say("superseded: televisions are offered %d, newer than %d", live, code)
			return nil
		case live < code:
			why = fmt.Sprintf("/api/app/latest still offers %d", live)
		case expect != "" && sum != "" && sum != expect:
			why = fmt.Sprintf("/api/app/latest describes sha256 %s, published %s", sum, expect)
		default:
			got, err := r.downloadSHA256("/api/app/f1tv.apk")
			if err == nil && (expect == "" || got == expect) {
				r.say("%s/api/app/latest offers %d and /api/app/f1tv.apk has sha256 %s", r.spec.Site, live, got)
				return nil
			}
			why = fmt.Sprintf("/api/app/f1tv.apk has sha256 %s (err %v), published %s", got, err, expect)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("after 5 minutes: %s", why)
		}
		time.Sleep(10 * time.Second)
	}
}

func (r *releaseRun) downloadSHA256(path string) (string, error) {
	resp, err := r.site.Get(r.spec.Site + path)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	h := sha256.New()
	if _, err := io.Copy(h, resp.Body); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
