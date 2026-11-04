# ===========================================================================
# network — default-VPC lookup + the k3s node Security Group.
# Implements the IRD-016 module contract:
#   22  -> none          (SSM-only management; no SSH keys exist by design)
#   6443/tcp <- self              (agent joins the server API/supervisor node-to-node)
#   6443/tcp <- NOTHING public    (MIN-50 / ADR-017: operator kubectl goes through an SSM
#                                  port-forward — scripts/k8s-tunnel.sh — not an allowlist)
#   80,443/tcp <- 0.0.0.0/0       (Traefik ingress — the only public surface)
#   self  8472/udp        (flannel VXLAN)   + 10250/tcp (kubelet)
# Break-glass (ADR-017): if SSM itself is broken, add a TEMPORARY 6443 rule via iac-manual,
# applied consciously and reverted — never a standing rule here.
# Modern per-rule resources (aws_vpc_security_group_*_rule) — one rule = one
# resource, self-reference via referenced_security_group_id.
# ===========================================================================

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "node" {
  # 6-part name {project}-{env}-{type}-{region}-{purpose} (IRD-013).
  name = "${var.name_prefix}-sg-${var.region_code}-node"
  # STALE BY DESIGN: "6443 from admin" no longer exists (MIN-50). Do NOT edit this string —
  # `description` is ForceNew on aws_security_group, so changing it would DESTROY and recreate
  # the SG the running nodes are attached to. Fix it only when the SG is being replaced anyway.
  description = "k3s nodes: 6443 from admin, 80/443 public, flannel/kubelet self, no SSH"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.name_prefix}-sg-${var.region_code}-node" }
}

# --- Ingress: public HTTP/HTTPS for Traefik ---------------------------------
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.node.id
  description       = "Traefik HTTP"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.node.id
  description       = "Traefik HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- Ingress (self): k3s API/supervisor + flannel VXLAN + kubelet, node-to-node ---
# The agent joins the server on 6443. This self rule is the ONLY 6443 ingress left after
# MIN-50 and must stay: without it the agent never registers (kubelet never comes up).
# It is a different concern from operator access that merely shares the port.
resource "aws_vpc_security_group_ingress_rule" "api_self" {
  security_group_id            = aws_security_group.node.id
  description                  = "k3s API/supervisor node-to-node (agent to server join)"
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = var.api_port
  to_port                      = var.api_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "flannel_vxlan" {
  security_group_id            = aws_security_group.node.id
  description                  = "flannel VXLAN between nodes"
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "kubelet" {
  security_group_id            = aws_security_group.node.id
  description                  = "kubelet metrics/exec between nodes"
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

# --- Egress: all (nodes pull images, reach SSM/S3/Route 53 endpoints) --------
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "all egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
