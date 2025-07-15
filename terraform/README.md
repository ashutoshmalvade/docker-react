# AWS Auto Scaling Environment with Terraform

This Terraform configuration creates a complete auto-scaling environment on AWS with high availability and automatic scaling based on CPU utilization.

## Architecture Overview

This configuration creates the following AWS resources:

### Networking
- **VPC** with DNS support enabled
- **Public Subnets** (2) for load balancer and NAT gateways
- **Private Subnets** (2) for EC2 instances
- **Internet Gateway** for public internet access
- **NAT Gateways** (2) for private subnet internet access
- **Route Tables** with appropriate routing

### Security
- **Security Group for ALB** - allows HTTP (80) and HTTPS (443) traffic
- **Security Group for EC2** - allows traffic from ALB on ports 80 and 8080

### Compute & Auto Scaling
- **Launch Template** with Amazon Linux 2 AMI
- **Auto Scaling Group** with configurable min/max/desired capacity
- **Auto Scaling Policies** for scale-up and scale-down
- **CloudWatch Alarms** for CPU-based scaling triggers

### Load Balancing
- **Application Load Balancer** in public subnets
- **Target Group** with health checks
- **Load Balancer Listener** on port 80

### Monitoring
- **CloudWatch Alarms** for high/low CPU utilization
- **CloudWatch Agent** installed on instances for detailed metrics

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Terraform** >= 1.0 installed
3. **AWS Key Pair** (optional, for SSH access to instances)

## Quick Start

1. **Clone or download** this Terraform configuration

2. **Configure variables** (copy and modify the example):
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your desired values
   ```

3. **Initialize Terraform**:
   ```bash
   cd terraform/
   terraform init
   ```

4. **Plan the deployment**:
   ```bash
   terraform plan
   ```

5. **Apply the configuration**:
   ```bash
   terraform apply
   ```

6. **Access your application**:
   After deployment completes, use the `application_url` output to access your application.

## Configuration Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for deployment | `us-west-2` | No |
| `environment` | Environment name (dev/staging/prod) | `dev` | No |
| `project_name` | Name of the project | `autoscaling-app` | No |
| `vpc_cidr` | CIDR block for VPC | `10.0.0.0/16` | No |
| `availability_zones` | List of AZs to use | `["us-west-2a", "us-west-2b"]` | No |
| `public_subnet_cidrs` | CIDR blocks for public subnets | `["10.0.1.0/24", "10.0.2.0/24"]` | No |
| `private_subnet_cidrs` | CIDR blocks for private subnets | `["10.0.10.0/24", "10.0.20.0/24"]` | No |
| `instance_type` | EC2 instance type | `t3.micro` | No |
| `min_size` | Minimum instances in ASG | `1` | No |
| `max_size` | Maximum instances in ASG | `3` | No |
| `desired_capacity` | Desired instances in ASG | `2` | No |
| `key_pair_name` | AWS key pair name for SSH access | `""` | No |
| `allowed_cidr_blocks` | CIDR blocks allowed to access ALB | `["0.0.0.0/0"]` | No |

## Auto Scaling Behavior

The auto scaling group automatically adjusts capacity based on CPU utilization:

- **Scale Up**: When average CPU > 70% for 2 consecutive 5-minute periods
- **Scale Down**: When average CPU < 20% for 2 consecutive 5-minute periods
- **Cooldown**: 5 minutes between scaling actions

## Security Considerations

### Network Security
- EC2 instances are placed in private subnets
- Only ALB security group can access EC2 instances
- NAT gateways provide outbound internet access for instances

### Recommended Security Enhancements
1. **Restrict ALB access**: Change `allowed_cidr_blocks` to your specific IP ranges
2. **Enable HTTPS**: Add SSL certificate to ALB listener
3. **SSH Access**: Create a bastion host if SSH access is needed
4. **WAF**: Consider adding AWS WAF for additional protection

## Monitoring and Logging

### CloudWatch Metrics
- CPU utilization monitoring with alarms
- Custom metrics via CloudWatch agent
- Auto scaling activities logged

### Health Checks
- ALB health checks on `/` endpoint
- Target group health monitoring
- Unhealthy instances automatically replaced

## Cost Optimization

### Cost Factors
- NAT Gateways (main cost driver)
- EC2 instances (consider Spot instances for dev environments)
- Load balancer hours
- Data transfer costs

### Cost Optimization Tips
1. Use single NAT gateway for dev environments
2. Consider t3/t4g instances for better cost/performance
3. Enable detailed monitoring only when needed
4. Use Spot instances for non-critical workloads

## Customization

### Application Deployment
The `user_data.sh` script installs and configures:
- Apache HTTP server
- Docker (for containerized applications)
- CloudWatch agent
- Sample web application

To deploy your own application:
1. Modify `user_data.sh` to install your application
2. Update security group rules if different ports are needed
3. Adjust health check path in target group

### Multi-Environment Deployment
Use different `.tfvars` files for different environments:
```bash
terraform apply -var-file="dev.tfvars"
terraform apply -var-file="staging.tfvars"
terraform apply -var-file="prod.tfvars"
```

## Outputs

After successful deployment, you'll see:
- `application_url`: URL to access your application
- `load_balancer_dns_name`: ALB DNS name
- `vpc_id`: VPC identifier
- `autoscaling_group_name`: ASG name
- Various resource IDs and ARNs

## Cleanup

To destroy all resources:
```bash
terraform destroy
```

**Warning**: This will permanently delete all resources. Make sure to backup any important data first.

## Troubleshooting

### Common Issues

1. **Instances not healthy**: Check security group rules and health check configuration
2. **Auto scaling not working**: Verify CloudWatch alarms and scaling policies
3. **Cannot access application**: Check ALB listener configuration and target group health

### Debugging Steps

1. **Check target group health**:
   ```bash
   aws elbv2 describe-target-health --target-group-arn <target-group-arn>
   ```

2. **View instance logs**:
   ```bash
   # SSH to instance (if key pair configured)
   sudo tail -f /var/log/user-data.log
   sudo systemctl status httpd
   ```

3. **Check auto scaling activities**:
   ```bash
   aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg-name>
   ```

## Best Practices

1. **State Management**: Use remote state with S3 backend for production
2. **Version Control**: Keep Terraform code in version control
3. **Environment Separation**: Use separate AWS accounts or regions for environments
4. **Resource Tagging**: Implement consistent tagging strategy
5. **Security**: Regular security reviews and updates
6. **Monitoring**: Set up comprehensive monitoring and alerting
7. **Backup**: Regular backups of critical data and configurations

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test your changes
4. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.