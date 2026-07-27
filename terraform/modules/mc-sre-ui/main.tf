# =============================================================================
# MC Monitoring Gateway
#
# Internet-facing NLB with static Elastic IPs, exposing ArgoCD and Prometheus
# from a Management Cluster to the RC monitoring ALB.
#
# Ingress is restricted to the RC VPC's NAT Gateway EIPs so only traffic
# routed through the RC ALB can reach this NLB.
#
# Ports:
#   8080  - ArgoCD server (HTTPS, TLS passthrough)
#   9090  - Prometheus (HTTP)
#
# The RC ALB performs OIDC authentication and path-based routing:
#   /mc01/argocd/*    → this NLB :8080
#   /mc01/prometheus/* → this NLB :9090
# =============================================================================

# -----------------------------------------------------------------------------
# Elastic IPs - one per public subnet AZ for stable NLB ingress addresses
# -----------------------------------------------------------------------------

resource "aws_eip" "nlb" {
  count  = length(var.public_subnet_ids)
  domain = "vpc"

  tags = {
    Name = "${var.management_id}-sre-eip-${count.index}"
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "nlb" {
  name        = "${var.management_id}-sre"
  description = "MC SRE UI NLB - ingress from RC NAT GW EIPs only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.management_id}-sre"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_rc_argocd" {
  for_each = toset(var.rc_nat_gateway_eips)

  security_group_id = aws_security_group.nlb.id
  description       = "Allow ArgoCD traffic from RC NAT GW ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = "${each.value}/32"
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_rc_prometheus" {
  for_each = toset(var.rc_nat_gateway_eips)

  security_group_id = aws_security_group.nlb.id
  description       = "Allow Prometheus traffic from RC NAT GW ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 9090
  to_port           = 9090
  cidr_ipv4         = "${each.value}/32"
}

# Node SG ingress: allow NLB to reach pods on ArgoCD and Prometheus ports
resource "aws_vpc_security_group_ingress_rule" "nodes_from_nlb_argocd" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow MC SRE UI NLB traffic to ArgoCD pods (port 8080)"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.nlb.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_nlb_prometheus" {
  security_group_id            = var.node_security_group_id
  description                  = "Allow MC SRE UI NLB traffic to Prometheus pods (port 9090)"
  ip_protocol                  = "tcp"
  from_port                    = 9090
  to_port                      = 9090
  referenced_security_group_id = aws_security_group.nlb.id
}

# -----------------------------------------------------------------------------
# Network Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "monitoring_gateway" {
  name               = "${var.management_id}-sre"
  internal           = false
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]

  dynamic "subnet_mapping" {
    for_each = var.public_subnet_ids
    content {
      subnet_id     = subnet_mapping.value
      allocation_id = aws_eip.nlb[subnet_mapping.key].id
    }
  }

  tags = {
    Name = "${var.management_id}-sre"
  }
}

# -----------------------------------------------------------------------------
# Target Groups - IP type for TargetGroupBinding compatibility with EKS Auto Mode
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "argocd" {
  name        = "${var.management_id}-sre-argocd"
  port        = 8080
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTPS"
    path                = "/healthz"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name                   = "${var.management_id}-sre-argocd"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_target_group" "prometheus" {
  name        = "${var.management_id}-sre-prometheus"
  port        = 9090
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/-/ready"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name                   = "${var.management_id}-sre-prometheus"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# NLB Listeners - TCP passthrough; TLS is terminated at RC ALB or by ArgoCD
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "argocd" {
  load_balancer_arn = aws_lb.monitoring_gateway.arn
  port              = 8080
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.argocd.arn
  }
}

resource "aws_lb_listener" "prometheus" {
  load_balancer_arn = aws_lb.monitoring_gateway.arn
  port              = 9090
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prometheus.arn
  }
}
