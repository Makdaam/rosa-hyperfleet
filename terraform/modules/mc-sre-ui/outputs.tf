# =============================================================================
# MC Monitoring Gateway Outputs
# =============================================================================

output "nlb_dns_name" {
  description = "DNS name of the MC SRE UI NLB"
  value       = aws_lb.monitoring_gateway.dns_name
}

output "eip_public_ips" {
  description = "Public Elastic IPs attached to the NLB - used as static targets in the RC ALB"
  value       = aws_eip.nlb[*].public_ip
}

output "argocd_target_group_arn" {
  description = "ARN of the ArgoCD NLB target group"
  value       = aws_lb_target_group.argocd.arn
}

output "prometheus_target_group_arn" {
  description = "ARN of the Prometheus NLB target group"
  value       = aws_lb_target_group.prometheus.arn
}
