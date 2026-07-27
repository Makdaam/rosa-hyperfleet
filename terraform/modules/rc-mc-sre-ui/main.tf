# =============================================================================
# RC MC SRE UI - Application Load Balancer
#
# Internet-facing ALB in the RC account providing OIDC-protected path-based
# access to ArgoCD and Prometheus on each Management Cluster.
#
# Hostname: {mc_prefix}.sre.{deployment_name}.{environment_domain}
#           default: mc.sre.us-east-1.int0.rosa.devshift.net
#
# Path routing (one rule per MC per service):
#   /{mc_id}/argocd/*    -> MC NLB EIPs:8080 (ArgoCD, HTTPS passthrough)
#   /{mc_id}/prometheus/* -> MC NLB EIPs:9090 (Prometheus, HTTP)
#
# Traffic from this ALB exits the RC VPC via NAT Gateways. The MC NLBs
# restrict ingress to the RC NAT Gateway EIPs.
# =============================================================================

locals {
  has_domain = var.environment_domain != null && var.environment_domain != ""
  hostname   = local.has_domain ? "${var.mc_prefix}.sre.${var.deployment_name}.${var.environment_domain}" : null

  # AWS resource name prefix - cap at 10 chars to leave room for suffixes like
  # "-mc-mc01-prometheus" (19 chars), keeping total under the 32-char limit.
  tg_prefix = substr(var.regional_id, 0, min(length(var.regional_id), 10))

  # Services exposed per MC
  services = {
    argocd = {
      port            = 8080
      health_protocol = "HTTPS"
      health_path     = "/healthz"
      priority_offset = 0
    }
    prometheus = {
      port            = 9090
      health_protocol = "HTTP"
      health_path     = "/-/ready"
      priority_offset = 10
    }
  }

  # Sorted MC IDs for deterministic priority assignment
  mc_ids_sorted = sort(keys(var.mc_endpoints))

  # Cross product of MCs x services for target groups and listener rules
  mc_service_pairs = {
    for pair in flatten([
      for mc_id in local.mc_ids_sorted : [
        for svc_key, svc in local.services : {
          key      = "${mc_id}-${svc_key}"
          mc_id    = mc_id
          svc_key  = svc_key
          svc      = svc
          mc_index = index(local.mc_ids_sorted, mc_id)
          eips     = var.mc_endpoints[mc_id].eips
          priority = (index(local.mc_ids_sorted, mc_id) + 1) * 100 + svc.priority_offset
        }
      ]
    ]) : pair.key => pair
  }

  # Flattened EIP attachments: one entry per MC x service x EIP
  eip_attachments = {
    for item in flatten([
      for key, pair in local.mc_service_pairs : [
        for idx, eip in pair.eips : {
          key    = "${key}-${idx}"
          tg_key = key
          eip    = eip
        }
      ]
    ]) : item.key => item
  }

  oidc_authorization_endpoint = "${var.oidc_issuer_url}/protocol/openid-connect/auth"
  oidc_token_endpoint         = "${var.oidc_issuer_url}/protocol/openid-connect/token"
  oidc_user_info_endpoint     = "${var.oidc_issuer_url}/protocol/openid-connect/userinfo"
}

# -----------------------------------------------------------------------------
# Access logs S3 bucket (FedRAMP AU-09, AU-11)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_elb_service_account" "current" {}

resource "aws_s3_bucket" "access_logs" {
  bucket = "${var.regional_id}-mc-sre-alb-logs"

  tags = {
    Name = "${var.regional_id}-mc-sre-alb-logs"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-log-retention"
    status = "Enabled"

    transition {
      days          = var.access_logs_standard_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.access_logs_standard_days + var.access_logs_glacier_days
    }
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ELBAccessLogs"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.current.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "DenyNonTLS"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# ACM Certificate (DNS-validated)
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "mc_sre" {
  count = local.has_domain ? 1 : 0

  domain_name       = local.hostname
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "cert_validation" {
  count = local.has_domain ? 1 : 0

  zone_id         = var.regional_hosted_zone_id
  name            = tolist(aws_acm_certificate.mc_sre[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.mc_sre[0].domain_validation_options)[0].resource_record_type
  ttl             = 300
  records         = [tolist(aws_acm_certificate.mc_sre[0].domain_validation_options)[0].resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "mc_sre" {
  count = local.has_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.mc_sre[0].arn
  validation_record_fqdns = [aws_route53_record.cert_validation[0].fqdn]
}

resource "aws_route53_record" "mc_sre" {
  count = local.has_domain ? 1 : 0

  zone_id = var.regional_hosted_zone_id
  name    = local.hostname
  type    = "A"

  alias {
    name                   = aws_lb.mc_sre.dns_name
    zone_id                = aws_lb.mc_sre.zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.regional_id}-mc-sre-alb"
  description = "Security group for RC MC SRE UI ALB"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.regional_id}-mc-sre-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_from_cidr" {
  count = length(var.allowed_source_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from ${var.allowed_source_cidrs[count.index]}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.allowed_source_cidrs[count.index]
}

# Egress: HTTPS to OIDC identity provider (dynamic IPs - see comment)
#
# Destination: 0.0.0.0/0 - exception acknowledged.
# The OIDC provider resolves via dynamic IPs on Red Hat's CDN/load balancing
# infrastructure. No stable CIDR block or AWS managed prefix list is published.
#
# Compensating controls:
#   - Rule only exists when var.oidc_enabled = true (opt-in, not default)
#   - Restricted to TCP:443 (HTTPS) only - no broad egress
#   - ALB ingress is already restricted to allowed_source_cidrs
#   - OIDC token exchange is mutually authenticated (client_id + client_secret)
resource "aws_vpc_security_group_egress_rule" "alb_to_oidc" {
  count = var.oidc_enabled ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS to OIDC IdP for token exchange (0.0.0.0/0 - dynamic IdP IPs)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Egress: to MC NLB EIPs on ArgoCD and Prometheus ports
resource "aws_vpc_security_group_egress_rule" "alb_to_mc_argocd" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow traffic to MC NLBs on ArgoCD port (8080)"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_mc_prometheus" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow traffic to MC NLBs on Prometheus port (9090)"
  ip_protocol       = "tcp"
  from_port         = 9090
  to_port           = 9090
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "mc_sre" {
  name               = "${local.tg_prefix}-mc-sre"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  access_logs {
    bucket  = aws_s3_bucket.access_logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = { Name = "${var.regional_id}-mc-sre" }

  depends_on = [aws_s3_bucket_policy.access_logs]
}

resource "aws_lb_listener" "https" {
  count = local.has_domain ? 1 : 0

  load_balancer_arn = aws_lb.mc_sre.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.mc_sre[0].certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "http" {
  count = local.has_domain ? 0 : 1

  load_balancer_arn = aws_lb.mc_sre.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

locals {
  listener_arn = local.has_domain ? aws_lb_listener.https[0].arn : aws_lb_listener.http[0].arn
}

# -----------------------------------------------------------------------------
# Target Groups - one per MC per service, targeting MC NLB Elastic IPs
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "mc_service" {
  for_each = local.mc_service_pairs

  name        = "${local.tg_prefix}-mc-${each.value.mc_id}-${each.value.svc_key}"
  port        = each.value.svc.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = each.value.svc.health_path
    port                = "traffic-port"
    protocol            = each.value.svc.health_protocol
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.regional_id}-mc-${each.value.mc_id}-${each.value.svc_key}" }
}

# Register MC NLB Elastic IPs as static targets in each target group
resource "aws_lb_target_group_attachment" "mc_service_eip" {
  for_each = local.eip_attachments

  target_group_arn = aws_lb_target_group.mc_service[each.value.tg_key].arn
  target_id        = each.value.eip
  port             = local.mc_service_pairs[each.value.tg_key].svc.port
}

# -----------------------------------------------------------------------------
# Listener Rules - OIDC + path-based routing per MC per service
# -----------------------------------------------------------------------------

resource "aws_lb_listener_rule" "mc_service" {
  for_each = local.mc_service_pairs

  listener_arn = local.listener_arn
  priority     = each.value.priority

  dynamic "action" {
    for_each = var.oidc_enabled ? [1] : []
    content {
      order = 1
      type  = "authenticate-oidc"
      authenticate_oidc {
        issuer                     = var.oidc_issuer_url
        authorization_endpoint     = local.oidc_authorization_endpoint
        token_endpoint             = local.oidc_token_endpoint
        user_info_endpoint         = local.oidc_user_info_endpoint
        client_id                  = var.oidc_client_id
        client_secret              = var.oidc_client_secret
        scope                      = "openid email profile"
        session_timeout            = 28800
        on_unauthenticated_request = "authenticate"
      }
    }
  }

  action {
    order            = var.oidc_enabled ? 2 : 1
    type             = "forward"
    target_group_arn = aws_lb_target_group.mc_service[each.key].arn
  }

  condition {
    path_pattern {
      values = ["/${each.value.mc_id}/${each.value.svc_key}/*"]
    }
  }
}
