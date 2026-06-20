# Frontend ALB — internet-facing, public subnets
resource "aws_lb" "frontend_alb" {
  name               = var.frontend_alb_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.frontend_alb_sg_id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true

  tags = { Name = var.frontend_alb_name }
}

# Backend ALB — internal only, private subnets (never exposed to internet)
resource "aws_lb" "backend_alb" {
  name               = var.backend_alb_name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.backend_alb_sg_id]
  subnets            = var.backend_subnet_ids

  drop_invalid_header_fields = true

  tags = { Name = var.backend_alb_name }
}

# ── Listeners ────────────────────────────────────────────────────────────

resource "aws_lb_listener" "frontend_http" {
  load_balancer_arn = aws_lb.frontend_alb.arn
  port              = 80
  protocol          = "HTTP" # nosemgrep: terraform.aws.security.insecure-load-balancer-tls-version.insecure-load-balancer-tls-version
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "frontend_https" {
  load_balancer_arn = aws_lb.frontend_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
}

resource "aws_lb_listener" "backend_http" {
  load_balancer_arn = aws_lb.backend_alb.arn
  port              = 80
  protocol          = "HTTP" # nosemgrep: terraform.aws.security.insecure-load-balancer-tls-version.insecure-load-balancer-tls-version
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
}

# ── Target Groups ────────────────────────────────────────────────────────

resource "aws_lb_target_group" "frontend_tg" {
  name     = var.frontend_tg_name
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = var.frontend_tg_name }
}

resource "aws_lb_target_group" "backend_tg" {
  name     = var.backend_tg_name
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = var.backend_tg_name }
}
