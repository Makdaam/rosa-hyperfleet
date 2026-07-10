# =============================================================================
# ALB Access Logs (FedRAMP AU-09)
#
# S3 bucket with KMS encryption for ALB access logs. The ELB service requires
# a specific bucket policy to deliver logs; KMS SSE is applied after delivery.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_elb_service_account" "current" {}

# -----------------------------------------------------------------------------
# KMS Key for S3 encryption
# -----------------------------------------------------------------------------

resource "aws_kms_key" "access_logs" {
  description             = "KMS key for SRE ALB access logs S3 bucket"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.regional_id}-sre-alb-logs"
  }
}

resource "aws_kms_alias" "access_logs" {
  name          = "alias/${var.regional_id}-sre-alb-logs"
  target_key_id = aws_kms_key.access_logs.key_id
}

# -----------------------------------------------------------------------------
# S3 Bucket
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "access_logs" {
  bucket = "${var.regional_id}-sre-alb-logs"

  tags = {
    Name = "${var.regional_id}-sre-alb-logs"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.access_logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Bucket Policy
#
# ELB service account must be able to put objects. KMS encryption is applied
# by S3 after delivery, so the ELB service does not need kms:GenerateDataKey.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ELBAccessLogs"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.current.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.access_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid    = "DenyNonTLS"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:*"
        Resource = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}
