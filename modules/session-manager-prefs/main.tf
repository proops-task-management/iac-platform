# ===========================================================================
# session-manager-prefs — the account+region Session Manager preferences
# document (MIN-83, IRD-016 §module contracts).
#
# Session Manager reads its preferences (idle timeout, logging, run-as, shell
# profile) from ONE document per account and region with an AWS-reserved name.
# Before this module it did not exist, so the account ran on AWS defaults —
# notably a 20-minute idle timeout that closes the operator's k3s API tunnel
# (scripts/k8s-tunnel.sh, ADR-017) whenever kubectl is quiet for 20 minutes.
#
# Every input below is stated explicitly, not only the one being changed: if
# someone later saves "Preferences" in the console, the console rewrites the
# whole document, and an explicit baseline turns that into a visible plan diff
# instead of a silent drift.
# ===========================================================================

locals {
  # why: an AWS contract, not a choice — Session Manager looks up preferences by
  # exactly this name. Any other name creates an unused document.
  document_name = "SSM-SessionManagerRunShell"
}

resource "aws_ssm_document" "this" {
  name            = local.document_name
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences - managed by Terraform (iac-platform modules/session-manager-prefs, MIN-83). Do not edit in the console."
    sessionType   = "Standard_Stream"
    inputs = {
      idleSessionTimeout = tostring(var.idle_session_timeout_minutes)
      maxSessionDuration = "" # empty = no hard cap beyond the idle timeout (AWS default)

      # Session-content logging stays OFF (AWS default, $0). Session start/end are
      # still recorded by CloudTrail (StartSession / TerminateSession, ADR-017).
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = true
      cloudWatchLogGroupName      = ""
      cloudWatchEncryptionEnabled = true
      cloudWatchStreamingEnabled  = false
      kmsKeyId                    = ""

      runAsEnabled     = false
      runAsDefaultUser = ""
      shellProfile = {
        linux   = ""
        windows = ""
      }
    }
  })
}
