# Wrongmove — adding a user

Wrongmove (`wrongmove.viktorbarzin.me`) has two ways in, and one account per
email address serves both.

## Someone who signs themselves up

Nothing to do. Registration has been open since 2026-08-10 — anyone can create
an account with a passkey, and each new account posts to Slack `#alerts`.

An address that already has an account is refused at signup ("An account already
exists for this email. Sign in instead."), so a returning user should use the
**Sign In** tab rather than **Sign Up**.

## Someone who signs in through Authentik

Adding a person to the **Wrongmove Users** group is two steps, not one:

1. Add them to the group (`./authentik-invite.sh assign <username> "Wrongmove Users"`).
2. **Reserve their row in the app database**, so nobody can register a passkey
   on their address before they first sign in.

Step 2 uses the app's own repository API from inside a running api pod:

```sh
POD=$(kubectl get pods -n realestate-crawler -l app=realestate-crawler-api \
    --field-selector=status.phase=Running -o name | head -1 | cut -d/ -f2)

kubectl exec -n realestate-crawler "$POD" -- python - <<'PY'
from database import engine
from repositories.user_repository import UserRepository

repo = UserRepository(engine)
for email in ["<their-email>"]:
    if repo.get_user_by_email(email) is None:
        repo.create_user(email)
        print("reserved", email)
    else:
        print("already present", email)
PY
```

### Why step 2 matters

The app resolves an authenticated caller to a database row by email, whichever
issuer vouched for them, and a row is otherwise created lazily on first use. The
email a passkey signup asserts is not verified. So between joining the group and
first signing in, an address with no row could be registered by someone else,
who would then share the account the real owner lands in.

A reserved row closes that window: registration refuses any address that already
has one. The row carries no credentials and does not affect SSO login.

Reserved as of 2026-08-10: `kadir.tugan@gmail.com`, `ancaelena98@gmail.com`,
`anca.r.cristian10@gmail.com`. `vbarzin@gmail.com` already had an account.

These rows are inserted by hand and are not reproduced from the repository, so
they would need re-creating if the database were ever rebuilt.

## Related

- Design: `realestate-crawler` → `docs/plans/2026-08-10-open-signup-and-signup-alerts.md`
- Stack: `stacks/real-estate-crawler/main.tf`
- Groups: `docs/architecture/authentication.md`
