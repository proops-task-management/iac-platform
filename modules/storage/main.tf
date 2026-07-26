# ===========================================================================
# storage — db-backups + plan-artifacts S3 buckets.
# Both: versioned, SSE-AES256, ALL public access blocked. Lifecycle rules keep
# them cheap. No force_destroy on the backups bucket (stateful — IRD-013).
# ===========================================================================

# --------------------------- DB backups -------------------------------------
resource "aws_s3_bucket" "dbbackups" {
  bucket = var.dbbackups_bucket_name
  tags   = { Name = var.dbbackups_bucket_name }
  # no force_destroy — this holds the only off-cluster copy of MySQL (IRD-013).
}

resource "aws_s3_bucket_versioning" "dbbackups" {
  bucket = aws_s3_bucket.dbbackups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dbbackups" {
  bucket = aws_s3_bucket.dbbackups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "dbbackups" {
  bucket                  = aws_s3_bucket.dbbackups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "dbbackups" {
  bucket = aws_s3_bucket.dbbackups.id
  rule {
    id     = "expire-old-dumps"
    status = "Enabled"
    filter {}
    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }
  }
}

# ------------------------- Plan artifacts -----------------------------------
resource "aws_s3_bucket" "planartifacts" {
  bucket = var.planartifacts_bucket_name
  tags   = { Name = var.planartifacts_bucket_name }
}

resource "aws_s3_bucket_versioning" "planartifacts" {
  bucket = aws_s3_bucket.planartifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "planartifacts" {
  bucket = aws_s3_bucket.planartifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "planartifacts" {
  bucket                  = aws_s3_bucket.planartifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "planartifacts" {
  bucket = aws_s3_bucket.planartifacts.id
  rule {
    id     = "expire-plan-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = var.planartifacts_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
