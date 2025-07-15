# AWS Auto Scaling Group with ELB and Additional EC2 Instances Setup Guide

This guide demonstrates how to create an AWS Auto Scaling Group (ASG) with 4 EC2 instances connected to an Application Load Balancer (ALB), plus 2 additional standalone EC2 instances added to the same target group.

## Architecture Overview

```
Internet Gateway
       |
Application Load Balancer
       |
Target Group
   /       \
ASG (4 instances)  +  Manual EC2 (2 instances)
```

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform installed (for Terraform approach)
- Valid AWS account with VPC, subnets, and security groups

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

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  map_public_ip_on_launch = true
  
  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
  }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Groups
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.main.id
  
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
  vpc_id      = aws_vpc.main.id
  
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
    cidr_blocks = [var.vpc_cidr]
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

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
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
  vpc_id   = aws_vpc.main.id
  
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
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.main.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300
  
  min_size         = 4
  max_size         = 6
  desired_capacity = 4
  
  launch_template {
    id      = aws_launch_template.launch_template.id
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
  subnet_id              = aws_subnet.private[count.index % 2].id
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

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Name of the AWS key pair"
  type        = string
  default     = ""
}
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
  value       = aws_vpc.main.id
}
```

### user-data.sh
```bash
#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd

# Create a simple HTML page
cat > /var/www/html/index.html << EOF
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
EOF

# Restart httpd to ensure changes take effect
systemctl restart httpd
```

## Option 2: AWS CloudFormation Template

### asg-elb-cloudformation.yaml
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Auto Scaling Group with 4 instances + 2 manual instances behind ALB'

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

Resources:
  # VPC Configuration
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.0.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-vpc'

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-igw'

  AttachGateway:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway

  # Public Subnets
  PublicSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-subnet-1'

  PublicSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.2.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-subnet-2'

  # Private Subnets
  PrivateSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.3.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-subnet-1'

  PrivateSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.0.4.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-private-subnet-2'

  # Route Tables
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-public-rt'

  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: AttachGateway
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetRouteTableAssociation1:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet1
      RouteTableId: !Ref PublicRouteTable

  PublicSubnetRouteTableAssociation2:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet2
      RouteTableId: !Ref PublicRouteTable

  # Security Groups
  ALBSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for Application Load Balancer
      VpcId: !Ref VPC
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
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          SourceSecurityGroupId: !Ref ALBSecurityGroup
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: 10.0.0.0/16
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-ec2-sg'

  # Application Load Balancer
  ApplicationLoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub '${ProjectName}-alb'
      Scheme: internet-facing
      Type: application
      SecurityGroups:
        - !Ref ALBSecurityGroup
      Subnets:
        - !Ref PublicSubnet1
        - !Ref PublicSubnet2
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
      VpcId: !Ref VPC
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
    --parameters ParameterKey=KeyPairName,ParameterValue=your-key-pair-name
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
# Remove instances from target group
aws elbv2 deregister-targets --target-group-arn <TARGET_GROUP_ARN> --targets Id=<INSTANCE_ID>,Port=80

# Terminate manual instances
aws ec2 terminate-instances --instance-ids <INSTANCE_ID_1> <INSTANCE_ID_2>

# Delete Auto Scaling Group
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name asg-elb-setup-asg --force-delete

# Delete other resources in reverse order...
```

## Best Practices

1. **Use Launch Templates** instead of Launch Configurations (deprecated)
2. **Enable detailed monitoring** for better scaling decisions
3. **Configure proper health checks** for your application
4. **Use multiple Availability Zones** for high availability
5. **Implement proper logging and monitoring**
6. **Use IAM roles** instead of access keys for EC2 instances
7. **Enable encryption** for EBS volumes and load balancer traffic
8. **Regular security updates** through automated patching

This setup provides a robust, scalable infrastructure with 4 Auto Scaling Group instances and 2 manual instances all serving traffic through a single Application Load Balancer.