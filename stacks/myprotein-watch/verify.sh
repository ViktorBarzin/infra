# shellcheck shell=bash
# Verify checks for stacks/myprotein-watch (docs/runbooks/verify-jobs.md). The
# stack is CronJobs only, so the floor runs nothing. A full run starts the
# price check once: it reads MyProtein's prices and posts to Slack only for a
# deal it has not announced before (state in a ConfigMap), so an extra run
# repeats nothing the 6-hourly schedule has already said.
VERIFY_GROUP="app"
VERIFY_NAMESPACES="myprotein-watch"
VERIFY_ALERTNAMES="^MyProteinWatch.*$"

verify_component() {
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "myprotein-watch price check Job completes" run_cronjob myprotein-watch myprotein-watch 300
  fi
}
