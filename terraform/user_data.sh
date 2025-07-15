#!/bin/bash

# Update the system
yum update -y

# Install required packages
yum install -y httpd
yum install -y docker
yum install -y aws-cli

# Start and enable httpd
systemctl start httpd
systemctl enable httpd

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Create a simple index.html file
cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
    <title>${project_name} - ${environment}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f4f4f4;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background-color: white;
            padding: 20px;
            border-radius: 10px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #333;
            text-align: center;
        }
        .info {
            background-color: #e7f3ff;
            border: 1px solid #b3d9ff;
            border-radius: 5px;
            padding: 15px;
            margin: 15px 0;
        }
        .status {
            color: green;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to ${project_name}</h1>
        <div class="info">
            <h3>Environment Information</h3>
            <p><strong>Environment:</strong> ${environment}</p>
            <p><strong>Instance ID:</strong> <span id="instance-id">Loading...</span></p>
            <p><strong>Availability Zone:</strong> <span id="az">Loading...</span></p>
            <p><strong>Status:</strong> <span class="status">Running</span></p>
        </div>
        <div class="info">
            <h3>Auto Scaling Status</h3>
            <p>This instance is part of an Auto Scaling Group that automatically adjusts capacity based on demand.</p>
            <p>Load balancer health checks are configured to monitor this endpoint.</p>
        </div>
        <div class="info">
            <h3>Health Check</h3>
            <p>Health Check Status: <span class="status">OK</span></p>
            <p>Timestamp: <span id="timestamp"></span></p>
        </div>
    </div>

    <script>
        // Get instance metadata
        fetch('http://169.254.169.254/latest/meta-data/instance-id')
            .then(response => response.text())
            .then(data => {
                document.getElementById('instance-id').textContent = data;
            })
            .catch(error => {
                document.getElementById('instance-id').textContent = 'Unable to fetch';
            });

        fetch('http://169.254.169.254/latest/meta-data/placement/availability-zone')
            .then(response => response.text())
            .then(data => {
                document.getElementById('az').textContent = data;
            })
            .catch(error => {
                document.getElementById('az').textContent = 'Unable to fetch';
            });

        // Update timestamp
        document.getElementById('timestamp').textContent = new Date().toLocaleString();
        
        // Refresh timestamp every 30 seconds
        setInterval(function() {
            document.getElementById('timestamp').textContent = new Date().toLocaleString();
        }, 30000);
    </script>
</body>
</html>
EOF

# Create a health check endpoint
cat <<EOF > /var/www/html/health
OK
EOF

# Set proper permissions
chown -R apache:apache /var/www/html/
chmod -R 755 /var/www/html/

# Install CloudWatch agent (optional)
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm

# Create a simple CloudWatch config
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/
cat <<EOF > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
    "metrics": {
        "namespace": "${project_name}/${environment}",
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "metrics_collection_interval": 60,
                "totalcpu": false
            },
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "diskio": {
                "measurement": [
                    "io_time"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 60
            }
        }
    }
}
EOF

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# Restart httpd to ensure everything is working
systemctl restart httpd

# Log completion
echo "User data script completed successfully at $(date)" >> /var/log/user-data.log