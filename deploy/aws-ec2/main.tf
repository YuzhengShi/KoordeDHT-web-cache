provider "aws" {
  region = var.region
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

# -----------------------------------------------------------------------------
# Network (VPC)
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "koorde-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "koorde-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "koorde-public-${count.index}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "koorde-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# -----------------------------------------------------------------------------
# Seed Node (for Bootstrap)
# -----------------------------------------------------------------------------

resource "aws_instance" "seed" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.node_sg.id]

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    bootstrap_mode  = "static"
    bootstrap_peers = "" # Seed node starts the ring
    region          = var.region
  }))

  tags = {
    Name = "koorde-seed"
  }
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb_sg" {
  name        = "koorde-alb-sg"
  description = "Allow HTTP inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "node_sg" {
  name        = "koorde-node-sg"
  description = "Allow internal traffic between nodes and from ALB"
  vpc_id      = aws_vpc.main.id

  # Allow traffic from ALB
  ingress {
    description     = "HTTP from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Allow internal gRPC and HTTP between nodes (self-referencing)
  ingress {
    description = "Internal gRPC"
    from_port   = 4000
    to_port     = 4002
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Internal HTTP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    self        = true
  }
  
  # Allow SSH (optional, for debugging)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # WARNING: Open to world, restrict in production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# Route53
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "main" {
  name = "koorde.internal"
  vpc {
    vpc_id = aws_vpc.main.id
  }
}

# -----------------------------------------------------------------------------
# Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "koorde-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "main" {
  name     = "koorde-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    matcher             = "200"
  }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# -----------------------------------------------------------------------------
# Auto Scaling Group
# -----------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  name_prefix   = "koorde-node-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  # No IAM profile needed for static bootstrap

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.node_sg.id]
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    bootstrap_mode  = "static"
    bootstrap_peers = "${aws_instance.seed.private_ip}:4000"
    region          = var.region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "koorde-node"
    }
  }
}

resource "aws_autoscaling_group" "bar" {
  desired_capacity    = var.node_count
  max_size            = 10
  min_size            = 3
  vpc_zone_identifier = aws_subnet.public[*].id
  target_group_arns   = [aws_lb_target_group.main.arn]

  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "koorde-node"
    propagate_at_launch = true
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "route53_zone_id" {
  value = "N/A (Static Bootstrap)"
}

output "seed_node_ip" {
  value = aws_instance.seed.public_ip
}
