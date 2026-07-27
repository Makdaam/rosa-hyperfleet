# =============================================================================
# MC Monitoring Gateway Variables
# =============================================================================

variable "management_id" {
  description = "Management cluster identifier used in resource names (e.g. mc01)"
  type        = string
}

variable "vpc_id" {
  description = "MC VPC ID where the NLB will be placed"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing NLB (at least 2 AZs)"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least 2 public subnets are required for NLB high availability."
  }
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID. For EKS Auto Mode, use cluster_primary_security_group_id."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - required for eks:eks-cluster-name tag (EKS Auto Mode IAM)"
  type        = string
}

variable "rc_nat_gateway_eips" {
  description = "Public Elastic IPs of the RC VPC's NAT Gateways. NLB ingress is restricted to these."
  type        = list(string)

  validation {
    condition     = length(var.rc_nat_gateway_eips) > 0
    error_message = "At least one RC NAT Gateway EIP must be provided."
  }
}
