# =============================================================================
# RC MC SRE UI Outputs
# =============================================================================

output "alb_dns_name" {
  description = "DNS name of the RC MC SRE UI ALB"
  value       = aws_lb.mc_sre.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the ALB (for Route53 alias records)"
  value       = aws_lb.mc_sre.zone_id
}

output "hostname" {
  description = "Hostname of the MC SRE UI ALB. Empty when environment_domain is not set."
  value       = local.has_domain ? local.hostname : ""
}
