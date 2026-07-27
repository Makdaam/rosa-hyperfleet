# =============================================================================
# RC MC SRE UI Module Variables
# =============================================================================

# =============================================================================
# Required
# =============================================================================

variable "vpc_id" {
  description = "RC VPC ID where the ALB will be created"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB (at least 2 AZs)"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least 2 public subnets are required for ALB high availability."
  }
}

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "allowed_source_cidrs" {
  description = "Source CIDRs allowed to reach the ALB. Required - must be non-empty."
  type        = list(string)

  validation {
    condition     = length(var.allowed_source_cidrs) > 0
    error_message = "allowed_source_cidrs must not be empty. Specify at least one source CIDR."
  }
}

# =============================================================================
# MC endpoints
#
# Map of management cluster IDs to their NLB Elastic IPs.
# The same EIPs serve both ArgoCD (port 8080) and Prometheus (port 9090) -
# the MC NLB has separate listeners per port.
# =============================================================================

variable "mc_endpoints" {
  description = "Map of management cluster IDs to their MC SRE UI NLB Elastic IPs."
  type = map(object({
    eips = list(string)
  }))
  default = {}
}

# =============================================================================
# DNS / TLS
# =============================================================================

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional zone. When null, ACM cert and DNS records are not created."
  type        = string
  default     = null
}

variable "deployment_name" {
  description = "Logical deployment identifier used to compose the ALB hostname (e.g. us-east-1)"
  type        = string
}

variable "environment_domain" {
  description = "Base domain for the environment (e.g. int0.rosa.devshift.net). When null, ACM cert and Route53 records are skipped."
  type        = string
  default     = null
}

variable "mc_prefix" {
  description = "Hostname prefix for the MC SRE UI ALB. Composes to {mc_prefix}.sre.{deployment_name}.{environment_domain}."
  type        = string
  default     = "mc"
}

# =============================================================================
# Access log retention (FedRAMP AU-11)
# =============================================================================

variable "access_logs_standard_days" {
  description = "Days to keep access logs in S3 Standard before transitioning to Glacier."
  type        = number
  default     = 90
}

variable "access_logs_glacier_days" {
  description = "Days in Glacier before expiry. Total retention = standard_days + this value."
  type        = number
  default     = 275
}

# =============================================================================
# OIDC authentication (optional)
# =============================================================================

variable "oidc_enabled" {
  description = "When true, listener rules prepend an authenticate-oidc action before forwarding."
  type        = bool
  default     = false
}

variable "oidc_issuer_url" {
  description = "OIDC issuer base URL. Authorization, token, and userinfo endpoints are derived from this."
  type        = string
  default     = "https://auth.redhat.com/auth/realms/EmployeeIDP"
}

variable "oidc_client_id" {
  description = "OIDC client ID. Required when oidc_enabled = true."
  type        = string
  default     = ""
}

variable "oidc_client_secret" {
  description = "OIDC client secret."
  type        = string
  default     = ""
  sensitive   = true
}
