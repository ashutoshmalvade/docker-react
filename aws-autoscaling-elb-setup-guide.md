# AWS Auto Scaling Group with ELB, ElastiCache, Aurora RDS, and EFS Setup Guide

This guide demonstrates how to create a complete AWS infrastructure including:
- Auto Scaling Group (ASG) with 4 EC2 instances connected to an Application Load Balancer (ALB)
- 2 additional standalone EC2 instances added to the same target group
- ElastiCache Redis cluster for caching
- Aurora RDS cluster created from snapshot for database
- EFS file system with provisioned throughput for shared storage

## Architecture Overview

```
Existing VPC
       |
┌─────────────────────────────────────────────────┐
│  Application Load Balancer (Public Subnets)     │
└─────────────────┬───────────────────────────────┘
                  │
┌─────────────────┴───────────────────────────────┐
│            Target Group                        │
│        /              \                        │
│  ASG (4 instances) + Manual EC2 (2 instances)  │
│           (Private Subnets)                    │
└─────────────────────────────────────────────────┘
                  │
    ┌─────────────┼─────────────┐
    │             │             │
┌───▼───┐   ┌─────▼─────┐   ┌───▼───┐
│  EFS  │   │ElastiCache│   │Aurora │
│       │   │   Redis   │   │  RDS  │
└───────┘   └───────────┘   └───────┘
```

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform installed (for Terraform approach)
- **Existing VPC with public and private subnets**
- **Internet Gateway attached to VPC**
- **Route tables configured for public subnets**

## Option 1: Terraform Implementation

### Directory Structure
```
aws-infrastructure/
├── main.tf
├── variables.tf
├── outputs.tf
├── user-data.sh
└── terraform.tfvars
```

### main.tf
```hcl
# Provider configuration
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources for existing infrastructure
data "aws_vpc" "existing" {
  id = var.vpc_id
}

data "aws_subnet" "public" {
  count = length(var.public_subnet_ids)
  id    = var.public_subnet_ids[count.index]
}

data "aws_subnet" "private" {
  count = length(var.private_subnet_ids)
  id    = var.private_subnet_ids[count.index]
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Security Groups
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = data.aws_vpc.existing.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for EC2 instances"
  vpc_id      = data.aws_vpc.existing.id
  
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}

# Security Group for RDS Aurora
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS Aurora cluster"
  vpc_id      = data.aws_vpc.existing.id
  
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# Security Group for ElastiCache
resource "aws_security_group" "elasticache" {
  name        = "${var.project_name}-elasticache-sg"
  description = "Security group for ElastiCache Redis cluster"
  vpc_id      = data.aws_vpc.existing.id
  
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-elasticache-sg"
  }
}

# Security Group for EFS
resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs-sg"
  description = "Security group for EFS file system"
  vpc_id      = data.aws_vpc.existing.id
  
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-efs-sg"
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
  
  enable_deletion_protection = false
  
  tags = {
    Name = "${var.project_name}-alb"
  }
}

# Target Group
resource "aws_lb_target_group" "main" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.existing.id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
    matcher             = "200"
    port                = "traffic-port"
    protocol            = "HTTP"
  }
  
  tags = {
    Name = "${var.project_name}-tg"
  }
}

# ALB Listener
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# Launch Template for Auto Scaling Group
resource "aws_launch_template" "main" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  key_name      = var.key_pair_name
  
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
  }
  
  user_data = base64encode(file("user-data.sh"))
  
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-asg-instance"
    }
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "main" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.main.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300
  
  min_size         = 4
  max_size         = 6
  desired_capacity = 4
  
  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }
  
  lifecycle {
    ignore_changes = [desired_capacity]
  }
  
  tag {
    key                 = "Name"
    value               = "${var.project_name}-asg"
    propagate_at_launch = false
  }
}

# Manual EC2 Instances (2 additional instances)
resource "aws_instance" "manual" {
  count                  = 2
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  subnet_id              = var.private_subnet_ids[count.index % length(var.private_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.ec2.id]
  
  user_data = file("user-data.sh")
  
  tags = {
    Name = "${var.project_name}-manual-instance-${count.index + 1}"
  }
}

# Attach manual instances to target group
resource "aws_lb_target_group_attachment" "manual" {
  count            = 2
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.manual[count.index].id
  port             = 80
}

# Auto Scaling Policies
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${var.project_name}-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.main.name
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${var.project_name}-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.main.name
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn]
  
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.project_name}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "10"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]
  
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }
}

# RDS Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids
  
  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# Aurora RDS Cluster from Snapshot
resource "aws_rds_cluster" "aurora" {
  cluster_identifier      = "${var.project_name}-aurora-cluster"
  engine                 = "aurora-mysql"
  engine_version         = var.aurora_engine_version
  database_name          = var.database_name
  master_username        = var.database_username
  master_password        = var.database_password
  backup_retention_period = 7
  preferred_backup_window = "07:00-09:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"
  
  # Create from snapshot
  snapshot_identifier = var.rds_snapshot_identifier
  
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  
  storage_encrypted = true
  
  skip_final_snapshot = false
  final_snapshot_identifier = "${var.project_name}-aurora-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  
  tags = {
    Name = "${var.project_name}-aurora-cluster"
  }
}

# Aurora RDS Instance
resource "aws_rds_cluster_instance" "aurora_instance" {
  count              = var.aurora_instance_count
  identifier         = "${var.project_name}-aurora-instance-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  
  performance_insights_enabled = true
  monitoring_interval = 60
  
  tags = {
    Name = "${var.project_name}-aurora-instance-${count.index + 1}"
  }
}

# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project_name}-cache-subnet-group"
  subnet_ids = var.private_subnet_ids
  
  tags = {
    Name = "${var.project_name}-cache-subnet-group"
  }
}

# ElastiCache Redis Cluster
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${var.project_name}-redis"
  description                = "Redis cluster for ${var.project_name}"
  
  node_type                  = var.redis_node_type
  port                       = 6379
  parameter_group_name       = "default.redis7"
  
  num_cache_clusters         = var.redis_num_cache_nodes
  
  engine_version             = var.redis_engine_version
  
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.elasticache.id]
  
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  
  maintenance_window         = "sun:05:00-sun:06:00"
  snapshot_retention_limit   = 5
  snapshot_window           = "03:00-05:00"
  
  automatic_failover_enabled = var.redis_num_cache_nodes > 1 ? true : false
  
  tags = {
    Name = "${var.project_name}-redis"
  }
}

# EFS File System
resource "aws_efs_file_system" "main" {
  creation_token   = "${var.project_name}-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "provisioned"
  provisioned_throughput_in_mibps = var.efs_provisioned_throughput
  
  encrypted = true
  
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }
  
  tags = {
    Name = "${var.project_name}-efs"
  }
}

# EFS Mount Targets
resource "aws_efs_mount_target" "main" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# EFS Access Point
resource "aws_efs_access_point" "main" {
  file_system_id = aws_efs_file_system.main.id
  
  posix_user {
    gid = 1001
    uid = 1001
  }
  
  root_directory {
    path = "/app"
    creation_info {
      owner_gid   = 1001
      owner_uid   = 1001
      permissions = "755"
    }
  }
  
  tags = {
    Name = "${var.project_name}-efs-access-point"
  }
}
```

### variables.tf
```hcl
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "asg-elb-setup"
}

variable "vpc_id" {
  description = "ID of existing VPC"
  type        = string
  validation {
    condition     = can(regex("^vpc-", var.vpc_id))
    error_message = "VPC ID must be a valid VPC identifier starting with 'vpc-'."
  }
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for ALB"
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least 2 public subnet IDs are required for ALB."
  }
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EC2 instances"
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnet IDs are required for high availability."
  }
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Name of the AWS key pair"
  type        = string
}

# Aurora RDS Variables
variable "rds_snapshot_identifier" {
  description = "Identifier of the RDS snapshot to restore from"
  type        = string
}

variable "database_name" {
  description = "Name of the database"
  type        = string
  default     = "myapp"
}

variable "database_username" {
  description = "Master username for the database"
  type        = string
  default     = "admin"
}

variable "database_password" {
  description = "Master password for the database"
  type        = string
  sensitive   = true
}

variable "aurora_engine_version" {
  description = "Aurora MySQL engine version"
  type        = string
  default     = "8.0.mysql_aurora.3.02.0"
}

variable "aurora_instance_class" {
  description = "Instance class for Aurora instances"
  type        = string
  default     = "db.r6g.large"
}

variable "aurora_instance_count" {
  description = "Number of Aurora instances"
  type        = number
  default     = 2
}

# ElastiCache Variables
variable "redis_node_type" {
  description = "Node type for Redis cluster"
  type        = string
  default     = "cache.r6g.large"
}

variable "redis_num_cache_nodes" {
  description = "Number of cache nodes in the Redis cluster"
  type        = number
  default     = 2
}

variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.0"
}

# EFS Variables
variable "efs_provisioned_throughput" {
  description = "Provisioned throughput for EFS in MiB/s"
  type        = number
  default     = 100
}
```

### terraform.tfvars (example)
```hcl
# Update these values with your existing infrastructure
vpc_id = "vpc-1234567890abcdef0"
public_subnet_ids = [
  "subnet-1234567890abcdef0",  # Public subnet in AZ1
  "subnet-0987654321fedcba0"   # Public subnet in AZ2
]
private_subnet_ids = [
  "subnet-abcdef1234567890a",  # Private subnet in AZ1
  "subnet-fedcba0987654321b"   # Private subnet in AZ2
]
key_pair_name = "my-key-pair"
project_name = "my-asg-elb"
aws_region = "us-east-1"

# RDS Configuration
rds_snapshot_identifier = "aurora-cluster-snapshot-2024-01-01"
database_password = "YourSecurePassword123!"
database_username = "admin"
database_name = "myapp"

# ElastiCache Configuration
redis_node_type = "cache.r6g.large"
redis_num_cache_nodes = 2

# EFS Configuration
efs_provisioned_throughput = 100
```

### outputs.tf
```hcl
output "load_balancer_dns" {
  description = "DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "ARN of the target group"
  value       = aws_lb_target_group.main.arn
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.main.name
}

output "manual_instance_ids" {
  description = "IDs of manual EC2 instances"
  value       = aws_instance.manual[*].id
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = data.aws_vpc.existing.id
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "redis_cluster_endpoint" {
  description = "Redis cluster endpoint"
  value       = aws_elasticache_replication_group.redis.configuration_endpoint_address
}

output "redis_cluster_port" {
  description = "Redis cluster port"
  value       = aws_elasticache_replication_group.redis.port
}

output "efs_file_system_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.main.id
}

output "efs_mount_target_dns_names" {
  description = "EFS mount target DNS names"
  value       = aws_efs_mount_target.main[*].dns_name
}

output "efs_access_point_id" {
  description = "EFS access point ID"
  value       = aws_efs_access_point.main.id
}
```

### user-data.sh
```bash
#!/bin/bash
yum update -y

# Install required packages
yum install -y httpd amazon-efs-utils mysql redis

# Start and enable httpd
systemctl start httpd
systemctl enable httpd

# Install AWS CLI v2 if not present
if ! command -v aws &> /dev/null; then
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

# Get EFS file system ID from tags (you'll need to update this with actual EFS ID)
# Or you can pass it as a parameter
EFS_ID="fs-XXXXXXXXX"  # Update this with your EFS ID

# Create mount point and mount EFS
mkdir -p /mnt/efs
echo "$EFS_ID.efs.$REGION.amazonaws.com:/ /mnt/efs efs defaults,_netdev,tls" >> /etc/fstab
mount -a

# Create app directory on EFS if it doesn't exist
mkdir -p /mnt/efs/app

# Create a simple HTML page
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Complete Infrastructure Instance</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .info-box { background: #f0f0f0; padding: 10px; margin: 10px 0; border-radius: 5px; }
        .service { display: inline-block; margin: 10px; padding: 15px; border: 1px solid #ccc; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>Hello from $(hostname -f)</h1>
    
    <div class="info-box">
        <h2>Instance Information</h2>
        <p><strong>Instance ID:</strong> $INSTANCE_ID</p>
        <p><strong>Availability Zone:</strong> $AZ</p>
        <p><strong>Instance Type:</strong> $INSTANCE_TYPE</p>
        <p><strong>Region:</strong> $REGION</p>
    </div>
    
    <div class="info-box">
        <h2>Available Services</h2>
        <div class="service">
            <h3>🗄️ Aurora MySQL</h3>
            <p>High-performance database cluster</p>
        </div>
        <div class="service">
            <h3>📊 ElastiCache Redis</h3>
            <p>In-memory caching service</p>
        </div>
        <div class="service">
            <h3>📁 EFS</h3>
            <p>Shared file system</p>
            <p>Mounted at: /mnt/efs</p>
        </div>
        <div class="service">
            <h3>⚖️ Application Load Balancer</h3>
            <p>Distributing traffic across instances</p>
        </div>
    </div>
    
    <div class="info-box">
        <h2>Health Check</h2>
        <p>Status: ✅ Healthy</p>
        <p>Last Updated: $(date)</p>
    </div>
</body>
</html>
EOF

# Create a simple status check script
cat > /var/www/html/health << EOF
#!/bin/bash
echo "OK"
EOF
chmod +x /var/www/html/health

# Set proper permissions
chown -R apache:apache /var/www/html/
chmod -R 755 /var/www/html/

# Restart httpd to ensure changes take effect
systemctl restart httpd

# Log completion
echo "$(date): User data script completed successfully" >> /var/log/user-data.log
```

## Option 2: AWS CloudFormation Template

### asg-elb-cloudformation.yaml
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Auto Scaling Group with 4 instances + 2 manual instances behind ALB using existing VPC'

Parameters:
  ProjectName:
    Type: String
    Default: asg-elb-setup
    Description: Name prefix for resources
  
  InstanceType:
    Type: String
    Default: t3.micro
    Description: EC2 instance type
  
  KeyPairName:
    Type: AWS::EC2::KeyPair::KeyName
    Description: Name of an existing EC2 KeyPair
  
  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: ID of existing VPC
  
  PublicSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: List of public subnet IDs for ALB (minimum 2 required)
  
  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: List of private subnet IDs for EC2 instances (minimum 2 required)
  
  RdsSnapshotIdentifier:
    Type: String
    Description: Identifier of the RDS snapshot to restore from
  
  DatabasePassword:
    Type: String
    NoEcho: true
    Description: Master password for the database
    MinLength: 8
  
  DatabaseUsername:
    Type: String
    Default: admin
    Description: Master username for the database
  
  DatabaseName:
    Type: String
    Default: myapp
    Description: Name of the database

Resources:

  # Security Groups
  ALBSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for Application Load Balancer
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-alb-sg'

  EC2SecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for EC2 instances
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          SourceSecurityGroupId: !Ref ALBSecurityGroup
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: 10.0.0.0/8  # Adjust this CIDR based on your VPC CIDR
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-ec2-sg'

  # Security Group for RDS Aurora
  RDSSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for RDS Aurora cluster
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 3306
          ToPort: 3306
          SourceSecurityGroupId: !Ref EC2SecurityGroup
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-rds-sg'

  # Security Group for ElastiCache
  ElastiCacheSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for ElastiCache Redis cluster
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 6379
          ToPort: 6379
          SourceSecurityGroupId: !Ref EC2SecurityGroup
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-elasticache-sg'

  # Security Group for EFS
  EFSSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for EFS file system
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 2049
          ToPort: 2049
          SourceSecurityGroupId: !Ref EC2SecurityGroup
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-efs-sg'

  # Application Load Balancer
  ApplicationLoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${ProjectName}-alb'
      Scheme: internet-facing
      Type: application
      SecurityGroups:
        - !Ref ALBSecurityGroup
      Subnets: !Ref PublicSubnetIds
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-alb'

  # Target Group
  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub '${ProjectName}-tg'
      Port: 80
      Protocol: HTTP
      VpcId: !Ref VpcId
      HealthCheckIntervalSeconds: 30
      HealthCheckPath: /
      HealthCheckProtocol: HTTP
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 2
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-tg'

  # ALB Listener
  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup
      LoadBalancerArn: !Ref ApplicationLoadBalancer
      Port: 80
      Protocol: HTTP

  # Launch Template
  LaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '${ProjectName}-lt'
      LaunchTemplateData:
        ImageId: ami-0abcdef1234567890  # Replace with latest Amazon Linux 2 AMI ID
        InstanceType: !Ref InstanceType
        KeyName: !Ref KeyPairName
        SecurityGroupIds:
          - !Ref EC2SecurityGroup
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            yum update -y
            yum install -y httpd
            systemctl start httpd
            systemctl enable httpd
            cat > /var/www/html/index.html << EOF
            <!DOCTYPE html>
            <html>
            <head><title>Load Balanced Instance</title></head>
            <body>
                <h1>Hello from $(hostname -f)</h1>
                <p>Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
                <p>Availability Zone: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</p>
            </body>
            </html>
            EOF
            systemctl restart httpd

  # Auto Scaling Group
  AutoScalingGroup:
    Type: AWS::AutoScaling::AutoScalingGroup
    Properties:
      AutoScalingGroupName: !Sub '${ProjectName}-asg'
      VPCZoneIdentifier:
        - !Ref PrivateSubnet1
        - !Ref PrivateSubnet2
      LaunchTemplate:
        LaunchTemplateId: !Ref LaunchTemplate
        Version: !GetAtt LaunchTemplate.LatestVersionNumber
      MinSize: 4
      MaxSize: 6
      DesiredCapacity: 4
      TargetGroupARNs:
        - !Ref TargetGroup
      HealthCheckType: ELB
      HealthCheckGracePeriod: 300
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-asg-instance'
          PropagateAtLaunch: true

  # Manual EC2 Instance 1
  ManualInstance1:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: ami-0abcdef1234567890  # Replace with latest Amazon Linux 2 AMI ID
      InstanceType: !Ref InstanceType
      KeyName: !Ref KeyPairName
      SubnetId: !Ref PrivateSubnet1
      SecurityGroupIds:
        - !Ref EC2SecurityGroup
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          yum update -y
          yum install -y httpd
          systemctl start httpd
          systemctl enable httpd
          cat > /var/www/html/index.html << EOF
          <!DOCTYPE html>
          <html>
          <head><title>Manual Instance 1</title></head>
          <body>
              <h1>Hello from Manual Instance 1 - $(hostname -f)</h1>
              <p>Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
              <p>Availability Zone: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</p>
          </body>
          </html>
          EOF
          systemctl restart httpd
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-manual-instance-1'

  # Manual EC2 Instance 2
  ManualInstance2:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: ami-0abcdef1234567890  # Replace with latest Amazon Linux 2 AMI ID
      InstanceType: !Ref InstanceType
      KeyName: !Ref KeyPairName
      SubnetId: !Ref PrivateSubnet2
      SecurityGroupIds:
        - !Ref EC2SecurityGroup
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          yum update -y
          yum install -y httpd
          systemctl start httpd
          systemctl enable httpd
          cat > /var/www/html/index.html << EOF
          <!DOCTYPE html>
          <html>
          <head><title>Manual Instance 2</title></head>
          <body>
              <h1>Hello from Manual Instance 2 - $(hostname -f)</h1>
              <p>Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
              <p>Availability Zone: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</p>
          </body>
          </html>
          EOF
          systemctl restart httpd
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-manual-instance-2'

  # Target Group Attachments for Manual Instances
  TargetGroupAttachment1:
    Type: AWS::ElasticLoadBalancingV2::TargetGroupAttachment
    Properties:
      TargetGroupArn: !Ref TargetGroup
      TargetId: !Ref ManualInstance1
      Port: 80

  TargetGroupAttachment2:
    Type: AWS::ElasticLoadBalancingV2::TargetGroupAttachment
    Properties:
      TargetGroupArn: !Ref TargetGroup
      TargetId: !Ref ManualInstance2
      Port: 80

  # RDS Subnet Group
  DBSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupDescription: Subnet group for RDS Aurora cluster
      SubnetIds: !Ref PrivateSubnetIds
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-db-subnet-group'

  # Aurora RDS Cluster from Snapshot
  AuroraCluster:
    Type: AWS::RDS::DBCluster
    Properties:
      DBClusterIdentifier: !Sub '${ProjectName}-aurora-cluster'
      Engine: aurora-mysql
      EngineVersion: 8.0.mysql_aurora.3.02.0
      DatabaseName: !Ref DatabaseName
      MasterUsername: !Ref DatabaseUsername
      MasterUserPassword: !Ref DatabasePassword
      BackupRetentionPeriod: 7
      PreferredBackupWindow: "07:00-09:00"
      PreferredMaintenanceWindow: "sun:05:00-sun:06:00"
      SnapshotIdentifier: !Ref RdsSnapshotIdentifier
      VpcSecurityGroupIds:
        - !Ref RDSSecurityGroup
      DBSubnetGroupName: !Ref DBSubnetGroup
      StorageEncrypted: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-aurora-cluster'

  # Aurora RDS Instance 1
  AuroraInstance1:
    Type: AWS::RDS::DBInstance
    Properties:
      DBInstanceIdentifier: !Sub '${ProjectName}-aurora-instance-1'
      DBClusterIdentifier: !Ref AuroraCluster
      DBInstanceClass: db.r6g.large
      Engine: aurora-mysql
      PerformanceInsightsEnabled: true
      MonitoringInterval: 60
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-aurora-instance-1'

  # Aurora RDS Instance 2
  AuroraInstance2:
    Type: AWS::RDS::DBInstance
    Properties:
      DBInstanceIdentifier: !Sub '${ProjectName}-aurora-instance-2'
      DBClusterIdentifier: !Ref AuroraCluster
      DBInstanceClass: db.r6g.large
      Engine: aurora-mysql
      PerformanceInsightsEnabled: true
      MonitoringInterval: 60
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-aurora-instance-2'

  # ElastiCache Subnet Group
  CacheSubnetGroup:
    Type: AWS::ElastiCache::SubnetGroup
    Properties:
      Description: Subnet group for ElastiCache Redis cluster
      SubnetIds: !Ref PrivateSubnetIds
      CacheSubnetGroupName: !Sub '${ProjectName}-cache-subnet-group'

  # ElastiCache Redis Replication Group
  RedisReplicationGroup:
    Type: AWS::ElastiCache::ReplicationGroup
    Properties:
      ReplicationGroupId: !Sub '${ProjectName}-redis'
      ReplicationGroupDescription: !Sub 'Redis cluster for ${ProjectName}'
      NodeType: cache.r6g.large
      Port: 6379
      CacheParameterGroupName: default.redis7
      NumCacheClusters: 2
      Engine: redis
      EngineVersion: 7.0
      CacheSubnetGroupName: !Ref CacheSubnetGroup
      SecurityGroupIds:
        - !Ref ElastiCacheSecurityGroup
      AtRestEncryptionEnabled: true
      TransitEncryptionEnabled: true
      PreferredMaintenanceWindow: "sun:05:00-sun:06:00"
      SnapshotRetentionLimit: 5
      SnapshotWindow: "03:00-05:00"
      AutomaticFailoverEnabled: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-redis'

  # EFS File System
  EFSFileSystem:
    Type: AWS::EFS::FileSystem
    Properties:
      CreationToken: !Sub '${ProjectName}-efs'
      PerformanceMode: generalPurpose
      ThroughputMode: provisioned
      ProvisionedThroughputInMibps: 100
      Encrypted: true
      LifecyclePolicyTransitionToIA: AFTER_30_DAYS
      LifecyclePolicyTransitionToPrimaryStorageClass: AFTER_1_ACCESS
      FileSystemTags:
        - Key: Name
          Value: !Sub '${ProjectName}-efs'

  # EFS Mount Target 1
  EFSMountTarget1:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref EFSFileSystem
      SubnetId: !Select [0, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EFSSecurityGroup

  # EFS Mount Target 2
  EFSMountTarget2:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref EFSFileSystem
      SubnetId: !Select [1, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EFSSecurityGroup

  # EFS Access Point
  EFSAccessPoint:
    Type: AWS::EFS::AccessPoint
    Properties:
      FileSystemId: !Ref EFSFileSystem
      PosixUser:
        Uid: 1001
        Gid: 1001
      RootDirectory:
        Path: "/app"
        CreationInfo:
          OwnerUid: 1001
          OwnerGid: 1001
          Permissions: "755"
      AccessPointTags:
        - Key: Name
          Value: !Sub '${ProjectName}-efs-access-point'

Outputs:
  LoadBalancerDNS:
    Description: DNS name of the load balancer
    Value: !GetAtt ApplicationLoadBalancer.DNSName
    Export:
      Name: !Sub '${ProjectName}-LoadBalancerDNS'

  TargetGroupArn:
    Description: ARN of the target group
    Value: !Ref TargetGroup
    Export:
      Name: !Sub '${ProjectName}-TargetGroupArn'

  AutoScalingGroupName:
    Description: Name of the Auto Scaling Group
    Value: !Ref AutoScalingGroup
    Export:
      Name: !Sub '${ProjectName}-AutoScalingGroupName'

  AuroraClusterEndpoint:
    Description: Aurora cluster endpoint
    Value: !GetAtt AuroraCluster.Endpoint.Address
    Export:
      Name: !Sub '${ProjectName}-AuroraClusterEndpoint'

  AuroraClusterReaderEndpoint:
    Description: Aurora cluster reader endpoint
    Value: !GetAtt AuroraCluster.ReadEndpoint.Address
    Export:
      Name: !Sub '${ProjectName}-AuroraClusterReaderEndpoint'

  RedisClusterEndpoint:
    Description: Redis cluster endpoint
    Value: !GetAtt RedisReplicationGroup.ConfigurationEndPoint.Address
    Export:
      Name: !Sub '${ProjectName}-RedisClusterEndpoint'

  RedisClusterPort:
    Description: Redis cluster port
    Value: !GetAtt RedisReplicationGroup.ConfigurationEndPoint.Port
    Export:
      Name: !Sub '${ProjectName}-RedisClusterPort'

  EFSFileSystemId:
    Description: EFS file system ID
    Value: !Ref EFSFileSystem
    Export:
      Name: !Sub '${ProjectName}-EFSFileSystemId'

  EFSAccessPointId:
    Description: EFS access point ID
    Value: !Ref EFSAccessPoint
    Export:
      Name: !Sub '${ProjectName}-EFSAccessPointId'
```

## Option 3: AWS CLI Commands

### Step-by-step CLI Implementation

```bash
#!/bin/bash

# Set variables
PROJECT_NAME="asg-elb-setup"
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_1_CIDR="10.0.1.0/24"
PUBLIC_SUBNET_2_CIDR="10.0.2.0/24"
PRIVATE_SUBNET_1_CIDR="10.0.3.0/24"
PRIVATE_SUBNET_2_CIDR="10.0.4.0/24"
INSTANCE_TYPE="t3.micro"
KEY_PAIR_NAME="your-key-pair"  # Replace with your key pair name

# 1. Create VPC
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT_NAME-vpc}]" \
    --query 'Vpc.VpcId' \
    --output text)

echo "Created VPC: $VPC_ID"

# Enable DNS hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# 2. Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$PROJECT_NAME-igw}]" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

echo "Created Internet Gateway: $IGW_ID"

# 3. Get Availability Zones
AZ1=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
AZ2=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)

# 4. Create Subnets
PUBLIC_SUBNET_1_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_1_CIDR \
    --availability-zone $AZ1 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT_NAME-public-subnet-1}]" \
    --query 'Subnet.SubnetId' \
    --output text)

PUBLIC_SUBNET_2_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_2_CIDR \
    --availability-zone $AZ2 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT_NAME-public-subnet-2}]" \
    --query 'Subnet.SubnetId' \
    --output text)

PRIVATE_SUBNET_1_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PRIVATE_SUBNET_1_CIDR \
    --availability-zone $AZ1 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT_NAME-private-subnet-1}]" \
    --query 'Subnet.SubnetId' \
    --output text)

PRIVATE_SUBNET_2_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PRIVATE_SUBNET_2_CIDR \
    --availability-zone $AZ2 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT_NAME-private-subnet-2}]" \
    --query 'Subnet.SubnetId' \
    --output text)

echo "Created Subnets: $PUBLIC_SUBNET_1_ID, $PUBLIC_SUBNET_2_ID, $PRIVATE_SUBNET_1_ID, $PRIVATE_SUBNET_2_ID"

# 5. Create Route Tables
RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT_NAME-public-rt}]" \
    --query 'RouteTable.RouteTableId' \
    --output text)

# Add route to Internet Gateway
aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Associate route table with public subnets
aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_1_ID --route-table-id $RT_ID
aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_2_ID --route-table-id $RT_ID

# 6. Create Security Groups
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "$PROJECT_NAME-alb-sg" \
    --description "Security group for Application Load Balancer" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT_NAME-alb-sg}]" \
    --query 'GroupId' \
    --output text)

# Add rules to ALB security group
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0

EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name "$PROJECT_NAME-ec2-sg" \
    --description "Security group for EC2 instances" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT_NAME-ec2-sg}]" \
    --query 'GroupId' \
    --output text)

# Add rules to EC2 security group
aws ec2 authorize-security-group-ingress --group-id $EC2_SG_ID --protocol tcp --port 80 --source-group $ALB_SG_ID
aws ec2 authorize-security-group-ingress --group-id $EC2_SG_ID --protocol tcp --port 22 --cidr $VPC_CIDR

echo "Created Security Groups: ALB=$ALB_SG_ID, EC2=$EC2_SG_ID"

# 7. Get latest Amazon Linux 2 AMI
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

echo "Using AMI: $AMI_ID"

# 8. Create user data script
cat > user-data.txt << 'EOF'
#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd

cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Load Balanced Instance</title>
</head>
<body>
    <h1>Hello from $(hostname -f)</h1>
    <p>Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
    <p>Availability Zone: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</p>
    <p>Instance Type: $(curl -s http://169.254.169.254/latest/meta-data/instance-type)</p>
</body>
</html>
HTML

systemctl restart httpd
EOF

# 9. Create Launch Template
LAUNCH_TEMPLATE_ID=$(aws ec2 create-launch-template \
    --launch-template-name "$PROJECT_NAME-lt" \
    --launch-template-data '{
        "ImageId":"'$AMI_ID'",
        "InstanceType":"'$INSTANCE_TYPE'",
        "KeyName":"'$KEY_PAIR_NAME'",
        "SecurityGroupIds":["'$EC2_SG_ID'"],
        "UserData":"'$(base64 -w 0 user-data.txt)'",
        "TagSpecifications":[{
            "ResourceType":"instance",
            "Tags":[{"Key":"Name","Value":"'$PROJECT_NAME'-asg-instance"}]
        }]
    }' \
    --query 'LaunchTemplate.LaunchTemplateId' \
    --output text)

echo "Created Launch Template: $LAUNCH_TEMPLATE_ID"

# 10. Create Application Load Balancer
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$PROJECT_NAME-alb" \
    --subnets $PUBLIC_SUBNET_1_ID $PUBLIC_SUBNET_2_ID \
    --security-groups $ALB_SG_ID \
    --tags Key=Name,Value="$PROJECT_NAME-alb" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)

echo "Created Load Balancer: $ALB_ARN"

# 11. Create Target Group
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name "$PROJECT_NAME-tg" \
    --protocol HTTP \
    --port 80 \
    --vpc-id $VPC_ID \
    --health-check-interval-seconds 30 \
    --health-check-path "/" \
    --health-check-protocol HTTP \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --tags Key=Name,Value="$PROJECT_NAME-tg" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

echo "Created Target Group: $TARGET_GROUP_ARN"

# 12. Create Listener
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
    --query 'Listeners[0].ListenerArn' \
    --output text)

echo "Created Listener: $LISTENER_ARN"

# 13. Create Auto Scaling Group
ASG_NAME="$PROJECT_NAME-asg"
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name $ASG_NAME \
    --launch-template LaunchTemplateId=$LAUNCH_TEMPLATE_ID,Version='$Latest' \
    --min-size 4 \
    --max-size 6 \
    --desired-capacity 4 \
    --vpc-zone-identifier "$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID" \
    --target-group-arns $TARGET_GROUP_ARN \
    --health-check-type ELB \
    --health-check-grace-period 300 \
    --tags "Key=Name,Value=$PROJECT_NAME-asg,PropagateAtLaunch=false,ResourceId=$ASG_NAME,ResourceType=auto-scaling-group"

echo "Created Auto Scaling Group: $ASG_NAME"

# 14. Create Manual EC2 Instances
MANUAL_INSTANCE_1_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $EC2_SG_ID \
    --subnet-id $PRIVATE_SUBNET_1_ID \
    --user-data file://user-data.txt \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_NAME-manual-instance-1}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

MANUAL_INSTANCE_2_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $EC2_SG_ID \
    --subnet-id $PRIVATE_SUBNET_2_ID \
    --user-data file://user-data.txt \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_NAME-manual-instance-2}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Created Manual Instances: $MANUAL_INSTANCE_1_ID, $MANUAL_INSTANCE_2_ID"

# 15. Wait for instances to be running
echo "Waiting for manual instances to be running..."
aws ec2 wait instance-running --instance-ids $MANUAL_INSTANCE_1_ID $MANUAL_INSTANCE_2_ID

# 16. Register manual instances with target group
aws elbv2 register-targets \
    --target-group-arn $TARGET_GROUP_ARN \
    --targets Id=$MANUAL_INSTANCE_1_ID,Port=80 Id=$MANUAL_INSTANCE_2_ID,Port=80

echo "Registered manual instances with target group"

# Get ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

echo "Setup complete!"
echo "Load Balancer DNS: $ALB_DNS"
echo "Target Group ARN: $TARGET_GROUP_ARN"
echo "Auto Scaling Group: $ASG_NAME"
echo "Manual Instance IDs: $MANUAL_INSTANCE_1_ID, $MANUAL_INSTANCE_2_ID"

# Clean up temporary file
rm user-data.txt
```

## Deployment Instructions

### For Terraform:
1. Save all files in a directory
2. Initialize: `terraform init`
3. Plan: `terraform plan`
4. Apply: `terraform apply`

### For CloudFormation:
```bash
aws cloudformation create-stack \
    --stack-name asg-elb-setup \
    --template-body file://asg-elb-cloudformation.yaml \
    --parameters \
        ParameterKey=KeyPairName,ParameterValue=your-key-pair-name \
        ParameterKey=VpcId,ParameterValue=vpc-1234567890abcdef0 \
        ParameterKey=PublicSubnetIds,ParameterValue="subnet-1234567890abcdef0,subnet-0987654321fedcba0" \
        ParameterKey=PrivateSubnetIds,ParameterValue="subnet-abcdef1234567890a,subnet-fedcba0987654321b" \
        ParameterKey=RdsSnapshotIdentifier,ParameterValue=aurora-cluster-snapshot-2024-01-01 \
        ParameterKey=DatabasePassword,ParameterValue=YourSecurePassword123!
```

### For AWS CLI:
1. Make the script executable: `chmod +x setup-infrastructure.sh`
2. Update the KEY_PAIR_NAME variable
3. Run: `./setup-infrastructure.sh`

## Verification

After deployment, verify your setup:

1. **Check Auto Scaling Group**: 
   ```bash
   aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names asg-elb-setup-asg
   ```

2. **Check Target Group Health**:
   ```bash
   aws elbv2 describe-target-health --target-group-arn <TARGET_GROUP_ARN>
   ```

3. **Test Load Balancer**:
   ```bash
   curl http://<LOAD_BALANCER_DNS>
   ```

4. **Check instances in target group**:
   ```bash
   aws elbv2 describe-target-group-attributes --target-group-arn <TARGET_GROUP_ARN>
   ```

5. **Check Aurora RDS cluster status**:
   ```bash
   aws rds describe-db-clusters --db-cluster-identifier <CLUSTER_NAME>
   ```

6. **Check ElastiCache Redis cluster status**:
   ```bash
   aws elasticache describe-replication-groups --replication-group-id <REDIS_GROUP_ID>
   ```

7. **Check EFS file system status**:
   ```bash
   aws efs describe-file-systems --file-system-id <EFS_ID>
   ```

## Testing Service Connectivity

### Test Database Connection (from EC2 instance):
```bash
# SSH into one of your EC2 instances
ssh -i your-key.pem ec2-user@<INSTANCE_IP>

# Test MySQL connection to Aurora
mysql -h <AURORA_ENDPOINT> -u admin -p
```

### Test Redis Connection (from EC2 instance):
```bash
# Install redis-cli if not already installed
sudo yum install -y redis

# Test Redis connection
redis-cli -h <REDIS_ENDPOINT> -p 6379 ping
```

### Test EFS Mount (from EC2 instance):
```bash
# Check if EFS is mounted
df -h | grep efs

# Test write to EFS
echo "Hello EFS" > /mnt/efs/test.txt
cat /mnt/efs/test.txt

# List files in shared directory
ls -la /mnt/efs/app/
```

### Application Example - Using All Services:
```bash
# Create a simple application script on EC2
cat > /home/ec2-user/test-services.sh << 'EOF'
#!/bin/bash

echo "=== Testing Complete Infrastructure ==="

# Test Aurora MySQL
echo "1. Testing Aurora MySQL connection..."
mysql -h $AURORA_ENDPOINT -u admin -p$DB_PASSWORD -e "SELECT VERSION();" 2>/dev/null && echo "✅ Aurora MySQL: Connected" || echo "❌ Aurora MySQL: Failed"

# Test Redis
echo "2. Testing Redis connection..."
redis-cli -h $REDIS_ENDPOINT -p 6379 ping 2>/dev/null && echo "✅ Redis: Connected" || echo "❌ Redis: Failed"

# Test EFS
echo "3. Testing EFS mount..."
[ -d "/mnt/efs" ] && echo "✅ EFS: Mounted" || echo "❌ EFS: Not mounted"

# Test writing to EFS
echo "4. Testing EFS write access..."
echo "Test $(date)" > /mnt/efs/test-$(hostname).txt 2>/dev/null && echo "✅ EFS: Write successful" || echo "❌ EFS: Write failed"

# Show instance info
echo "5. Instance Information:"
echo "   Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "   AZ: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)"

echo "=== Test Complete ==="
EOF

chmod +x /home/ec2-user/test-services.sh
```

## Managing the Setup

### Scale the Auto Scaling Group:
```bash
aws autoscaling set-desired-capacity \
    --auto-scaling-group-name asg-elb-setup-asg \
    --desired-capacity 6
```

### Add/Remove manual instances from target group:
```bash
# Remove
aws elbv2 deregister-targets \
    --target-group-arn <TARGET_GROUP_ARN> \
    --targets Id=<INSTANCE_ID>,Port=80

# Add
aws elbv2 register-targets \
    --target-group-arn <TARGET_GROUP_ARN> \
    --targets Id=<INSTANCE_ID>,Port=80
```

### Manage Aurora RDS Cluster:
```bash
# Scale Aurora cluster (add instance)
aws rds create-db-instance \
    --db-instance-identifier my-aurora-instance-3 \
    --db-cluster-identifier <CLUSTER_IDENTIFIER> \
    --db-instance-class db.r6g.large \
    --engine aurora-mysql

# Create Aurora snapshot
aws rds create-db-cluster-snapshot \
    --db-cluster-snapshot-identifier my-aurora-snapshot-$(date +%Y%m%d) \
    --db-cluster-identifier <CLUSTER_IDENTIFIER>

# Modify Aurora cluster
aws rds modify-db-cluster \
    --db-cluster-identifier <CLUSTER_IDENTIFIER> \
    --backup-retention-period 14 \
    --apply-immediately
```

### Manage ElastiCache Redis:
```bash
# Scale Redis cluster (add node)
aws elasticache modify-replication-group \
    --replication-group-id <REDIS_GROUP_ID> \
    --num-cache-clusters 3 \
    --apply-immediately

# Create Redis backup
aws elasticache create-snapshot \
    --cache-cluster-id <CACHE_CLUSTER_ID> \
    --snapshot-name redis-backup-$(date +%Y%m%d)

# Get Redis logs
aws elasticache describe-events \
    --source-identifier <REDIS_GROUP_ID> \
    --source-type replication-group
```

### Manage EFS:
```bash
# Modify EFS throughput
aws efs modify-file-system \
    --file-system-id <EFS_ID> \
    --provisioned-throughput-in-mibps 200

# Create EFS backup
aws efs put-backup-policy \
    --file-system-id <EFS_ID> \
    --backup-policy Status=ENABLED

# Monitor EFS performance
aws cloudwatch get-metric-statistics \
    --namespace AWS/EFS \
    --metric-name TotalIOBytes \
    --dimensions Name=FileSystemId,Value=<EFS_ID> \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 3600 \
    --statistics Sum
```

## Cleanup

### Terraform:
```bash
terraform destroy
```

### CloudFormation:
```bash
aws cloudformation delete-stack --stack-name asg-elb-setup
```

### Manual cleanup (if using CLI):
```bash
#!/bin/bash
# Complete infrastructure cleanup script

echo "Starting cleanup process..."

# 1. Remove manual instances from target group
echo "Removing manual instances from target group..."
aws elbv2 deregister-targets --target-group-arn <TARGET_GROUP_ARN> --targets Id=<MANUAL_INSTANCE_1>,Port=80
aws elbv2 deregister-targets --target-group-arn <TARGET_GROUP_ARN> --targets Id=<MANUAL_INSTANCE_2>,Port=80

# 2. Delete Auto Scaling Group (this will terminate ASG instances)
echo "Deleting Auto Scaling Group..."
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name <ASG_NAME> --force-delete

# 3. Wait for ASG deletion and then delete launch template
echo "Waiting for ASG deletion to complete..."
sleep 60
aws ec2 delete-launch-template --launch-template-id <LAUNCH_TEMPLATE_ID>

# 4. Terminate manual EC2 instances
echo "Terminating manual instances..."
aws ec2 terminate-instances --instance-ids <MANUAL_INSTANCE_1> <MANUAL_INSTANCE_2>

# 5. Delete EFS resources
echo "Deleting EFS resources..."
aws efs delete-access-point --access-point-id <EFS_ACCESS_POINT_ID>
aws efs delete-mount-target --mount-target-id <MOUNT_TARGET_1>
aws efs delete-mount-target --mount-target-id <MOUNT_TARGET_2>
sleep 30  # Wait for mount targets to be deleted
aws efs delete-file-system --file-system-id <EFS_ID>

# 6. Delete ElastiCache Redis cluster
echo "Deleting ElastiCache Redis cluster..."
aws elasticache delete-replication-group \
    --replication-group-id <REDIS_GROUP_ID> \
    --no-retain-primary-cluster

# Delete cache subnet group
aws elasticache delete-cache-subnet-group --cache-subnet-group-name <CACHE_SUBNET_GROUP>

# 7. Delete Aurora RDS cluster
echo "Deleting Aurora RDS cluster..."
# Delete instances first
aws rds delete-db-instance \
    --db-instance-identifier <AURORA_INSTANCE_1> \
    --skip-final-snapshot

aws rds delete-db-instance \
    --db-instance-identifier <AURORA_INSTANCE_2> \
    --skip-final-snapshot

# Wait for instances to be deleted
echo "Waiting for RDS instances to be deleted..."
sleep 300

# Delete cluster
aws rds delete-db-cluster \
    --db-cluster-identifier <AURORA_CLUSTER> \
    --skip-final-snapshot

# Delete DB subnet group
aws rds delete-db-subnet-group --db-subnet-group-name <DB_SUBNET_GROUP>

# 8. Delete Load Balancer components
echo "Deleting load balancer resources..."
aws elbv2 delete-listener --listener-arn <LISTENER_ARN>
aws elbv2 delete-target-group --target-group-arn <TARGET_GROUP_ARN>
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN>

# 9. Delete Security Groups (wait for dependencies to be removed first)
echo "Waiting for resources to be fully deleted before removing security groups..."
sleep 120

aws ec2 delete-security-group --group-id <EFS_SG_ID>
aws ec2 delete-security-group --group-id <ELASTICACHE_SG_ID>
aws ec2 delete-security-group --group-id <RDS_SG_ID>
aws ec2 delete-security-group --group-id <EC2_SG_ID>
aws ec2 delete-security-group --group-id <ALB_SG_ID>

echo "Cleanup completed!"
```

### Cost Optimization Tips:
```bash
# Stop Aurora cluster (if you want to preserve data but save costs)
aws rds stop-db-cluster --db-cluster-identifier <CLUSTER_IDENTIFIER>

# Reduce EFS provisioned throughput during low usage
aws efs modify-file-system \
    --file-system-id <EFS_ID> \
    --provisioned-throughput-in-mibps 50

# Scale down Auto Scaling Group during off hours
aws autoscaling set-desired-capacity \
    --auto-scaling-group-name <ASG_NAME> \
    --desired-capacity 2

# Create scheduled scaling for regular patterns
aws autoscaling create-scheduled-action \
    --auto-scaling-group-name <ASG_NAME> \
    --scheduled-action-name "scale-down-evening" \
    --schedule "0 22 * * *" \
    --desired-capacity 2

aws autoscaling create-scheduled-action \
    --auto-scaling-group-name <ASG_NAME> \
    --scheduled-action-name "scale-up-morning" \
    --schedule "0 8 * * 1-5" \
    --desired-capacity 4
```

## Best Practices

### General Infrastructure:
1. **Use Launch Templates** instead of Launch Configurations (deprecated)
2. **Enable detailed monitoring** for better scaling decisions
3. **Configure proper health checks** for your application
4. **Use multiple Availability Zones** for high availability
5. **Implement proper logging and monitoring**
6. **Use IAM roles** instead of access keys for EC2 instances
7. **Enable encryption** for EBS volumes and load balancer traffic
8. **Regular security updates** through automated patching

### Aurora RDS Best Practices:
1. **Enable automated backups** with appropriate retention period
2. **Use read replicas** for read-heavy workloads
3. **Enable Performance Insights** for query optimization
4. **Set up monitoring** for CPU, connections, and storage
5. **Use parameter groups** for custom database configurations
6. **Enable encryption at rest** for sensitive data
7. **Regular security patches** through maintenance windows
8. **Test disaster recovery** procedures regularly

### ElastiCache Redis Best Practices:
1. **Enable cluster mode** for high availability and scaling
2. **Use appropriate node types** for your workload
3. **Enable encryption** in transit and at rest
4. **Monitor memory usage** and eviction policies
5. **Set up CloudWatch alarms** for key metrics
6. **Use connection pooling** from applications
7. **Regular snapshots** for data persistence
8. **Test failover scenarios** periodically

### EFS Best Practices:
1. **Use provisioned throughput** for consistent performance
2. **Enable lifecycle policies** to optimize costs
3. **Monitor performance metrics** and adjust throughput
4. **Use EFS access points** for application-specific access
5. **Enable backup policies** for data protection
6. **Use VPC endpoints** for private connectivity
7. **Implement proper file permissions** and access controls
8. **Monitor file system utilization** and growth

### Security Best Practices:
1. **Use VPC security groups** with least privilege access
2. **Enable VPC Flow Logs** for network monitoring
3. **Use AWS Secrets Manager** for database credentials
4. **Implement network ACLs** for additional security layers
5. **Enable AWS Config** for compliance monitoring
6. **Use AWS CloudTrail** for API audit logging
7. **Regular security assessments** and vulnerability scans
8. **Implement WAF** for application layer protection

### Cost Optimization:
1. **Use Spot Instances** for non-critical workloads in ASG
2. **Implement scheduled scaling** for predictable patterns
3. **Monitor and optimize** EFS and RDS storage usage
4. **Use Reserved Instances** for long-term workloads
5. **Enable Cost Explorer** and billing alerts
6. **Regular cost reviews** and resource optimization
7. **Use AWS Trusted Advisor** recommendations
8. **Implement resource tagging** for cost allocation

## Architecture Summary

This comprehensive setup provides:

- **High Availability**: Multi-AZ deployment across all services
- **Scalability**: Auto Scaling Group with manual instances for flexibility
- **Performance**: 
  - Aurora MySQL for high-performance database operations
  - ElastiCache Redis for sub-millisecond caching
  - EFS with provisioned throughput for consistent file system performance
- **Security**: Network isolation with security groups and encryption
- **Monitoring**: CloudWatch integration across all services
- **Cost Optimization**: Flexible scaling and resource management

**Total Infrastructure Components:**
- ✅ 4 Auto Scaling Group EC2 instances
- ✅ 2 Manual EC2 instances  
- ✅ Application Load Balancer with target group
- ✅ Aurora MySQL cluster (2 instances)
- ✅ ElastiCache Redis cluster (2 nodes)
- ✅ EFS file system with provisioned throughput
- ✅ Security groups and networking
- ✅ CloudWatch monitoring and auto-scaling policies