require ["fileinto", "imap4flags"];

# Synology NAS_Barzini emails on every UPS transfer, including blips of a few
# seconds (2026-11-02, 2026-11-10). Viktor wants no alert for those
# (2026-11-10). Real outages are covered by Alertmanager's UPSOnBatteryEmail,
# which mails this mailbox after 1 minute on battery and every 10 minutes
# after. The NAS copies are kept, filed straight into Archive as read, for
# looking back at blips. Emil's copy of the same mail is not affected.
if allof (header :contains "from" "NAS_Barzini",
          header :contains "subject" "The UPS device connected to NAS_Barzini") {
    fileinto :flags "\\Seen" "Archive";
    stop;
}
