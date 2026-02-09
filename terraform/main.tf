terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # --- BACKEND CONFIGURATION ---
  # Terraform will store the state file in the S3 Bucket you created manually.
  # It will use DynamoDB for state locking to prevent concurrent edits.
  backend "s3" {
    bucket         = "voting-app-team-taco"    
    key            = "infra/terraform.tfstate"  # The path/filename inside the bucket
    region         = "eu-central-1"
    dynamodb_table = "voting-app-team-taco"          # The name of the table you created
    encrypt        = true
  }
}
provider "aws" {
  region = "eu-central-1"
}
# =========================================================================
# 1. NETWORKING (VPC & SUBNETS)
# =========================================================================
# The Main VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "vpc-taco" }
}
# Internet Gateway (Required for Public Subnet internet access)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "gateway-taco" }
}
# Public Subnet (Bastion / Frontend)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # Automatically assigns a Public IP
  availability_zone       = "eu-central-1a"
  tags = { Name = "pubnet-taco" }
}
# Private Subnet (Backend / Databases)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-central-1a"
  tags = { Name = "privnet-taco" }
}
# Route Table for Public Subnet
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  # Route all traffic (0.0.0.0/0) to the Internet Gateway
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "rt-taco" }
}
# Associate Route Table with Public Subnet
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}
# =========================================================================
# 2. SECURITY (SECURITY GROUPS)
# =========================================================================
# SG A: Vote/Result + Bastion (External Access)
resource "aws_security_group" "sg_vote_bastion" {
  name        = "taco-sg-bastion"
  description = "Allows HTTP/S and SSH from internet"
  vpc_id      = aws_vpc.main.id
  # SSH (Port 22)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # In production, restrict this to your specific IP
  }
  # HTTP (Port 80)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # HTTPS (Port 443)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # Outbound rules (Allow everything)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# SG B: Redis/Worker (Internal Access Only)
resource "aws_security_group" "sg_redis_worker" {
  name        = "taco-sg-redis"
  description = "Redis and Worker internal communication"
  vpc_id      = aws_vpc.main.id
  # Redis (6379) - Allow only from Group A (Vote App)
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_vote_bastion.id]
  }
  # SSH (22) - Allow only from Group A (Bastion)
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_vote_bastion.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# SG C: Postgres (Database Layer)
resource "aws_security_group" "sg_postgres" {
  name        = "taco-postgres-sg"
  description = "PostgreSQL Database"
  vpc_id      = aws_vpc.main.id
  # Postgres (5432) - Allow from Group B (Worker)
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_redis_worker.id]
  }
  # Postgres (5432) - Allow from Group A (Vote/Result if needed directly)
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_vote_bastion.id]
  }
  # SSH (22) - Allow only from Group A (Bastion)
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_vote_bastion.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# =========================================================================
# 3. INSTANCES (COMPUTE)
# =========================================================================
# Data Source: Find the latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}
# SSH Key Pair (Assumes you have id_rsa.pub locally)
resource "aws_key_pair" "deployer" {
  key_name   = "taco-key"
  public_key = file("/home/vascogama11/.ssh/id_rsa.pub") 
}
# INSTANCE A: BASTION + VOTE
resource "aws_instance" "instance_a" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.sg_vote_bastion.id]
  tags = { Name = "Taco - Bastion" }
}
# INSTANCE B: REDIS + WORKER
resource "aws_instance" "instance_b" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.private.id
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.sg_redis_worker.id]
  tags = { Name = "Taco - Redis/Worker" }
}
# INSTANCE C: POSTGRESQL
resource "aws_instance" "instance_c" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.private.id
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.sg_postgres.id]
  tags = { Name = "Taco - Postgres" }
}
# =========================================================================
# 4. OUTPUTS (Useful info displayed at the end)
# =========================================================================
output "bastion_ssh_command" {
  value = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.instance_a.public_ip}"
  description = "Command to SSH into the Bastion Host"
}
output "internal_ips" {
  value = {
    redis_worker = aws_instance.instance_b.private_ip
    postgres     = aws_instance.instance_c.private_ip
  }
  description = "Private IPs to be used inside the network (for Ansible/Docker config)"
}

