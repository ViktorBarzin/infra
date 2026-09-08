# Sender allowlist for the paperless-ngx ingest mailbox docs@viktorbarzin.me.
# Family members forward document emails here; paperless-ngx polls the INBOX
# over IMAP and maps each sender to a paperless account (1 mail rule per
# sender). Decision (Viktor, 2026-07-03): mail from any OTHER sender is
# ignored and deleted — discarded here at LMTP delivery, before paperless
# ever sees it. This also keeps spam to the guessable address out entirely.
#
# Keep this list in sync with the paperless mail rules (the sender -> owner
# map). Add-a-sender procedure: docs/runbooks/paperless-mail-ingest.md
if not address :is "from" ["me@viktorbarzin.me",
                           "vbarzin@gmail.com",
                           "viktorbarzin@meta.com",
                           "ancaelena98@gmail.com",
                           "emil.barzin@gmail.com"] {
    discard;
    stop;
}
