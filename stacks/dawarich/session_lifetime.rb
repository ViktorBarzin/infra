# Mounted into /var/app/config/initializers/ by stacks/dawarich/main.tf. The
# zz_ prefix makes Rails load it after the image's own devise.rb, so these
# values win over upstream's defaults.
#
# Upstream ships stock Devise: a 2-week "remember me" that does not renew, a
# browser-session cookie with no expiry, and a sign-out that cancels "remember
# me" on every device. In practice that meant signing in again every few days.
# Viktor asked (2026-10-19) for web sessions to stay signed in for a year,
# renewed on every visit.
Devise.setup do |config|
  config.remember_for = 1.year
  config.extend_remember_period = true
  # Signing out ends that browser's session only. To sign out everywhere,
  # change the password: Devise checks the password salt on every request.
  config.expire_all_remember_me_on_sign_out = false
  config.rememberable_options = { secure: true }
end

# expire_after re-sends the cookie on every request that carries a session,
# so the year counts from the last visit, not from sign-in.
Rails.application.config.session_store :cookie_store,
  key: "_dawarich_session",
  expire_after: 1.year,
  secure: true
