#############################
# Variables
#############################
variable "region" {
  default = "eu-west-1"
}

variable "environment" {
  default = "demo"
}

variable "profile" {
  default = "shayrm"
}

variable "ubuntu-ami" {
    default = "ami-0fd8802f94ed1c969"
}

variable "instance_type" {
  default = "t2.micro"
}

variable "instance_profile" {
  default = "ec2-role-c-demo"
  
}

variable "base_name" {
  default = "c-one-demo"
}

variable "bucket_name" {
  default = "c-one-demo"
}

variable "key_pair" {
  default = "c-one-demo"
}

#############################
# Locals
#############################
locals {
  base_name = "${var.environment}-${var.base_name}"
  tags = {
    "Name"        = local.base_name
    "Environment" = var.environment
  }
  cloudinit_config = <<EOF
#cloud-config
package_update: true
packages:
  - jq
  - apt-transport-https 
  - ca-certificates 
  - curl 
  - gnupg-agent 
  - software-properties-common
  - git
  - python3
  - python3-pip
runcmd:
# Install SSRF NodeJS
  - cd /opt
  - sudo git clone https://github.com/sethsec/Nodejs-SSRF-App.git
  - cd Nodejs-SSRF-App/
  - sudo ./install.sh
  - sudo nodejs ssrf-demo-app.js
EOF
}

#############################
# Providers
#############################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
  
}

provider "aws" {
  region = var.region
  # profile = "${var.profile}" 
}

#############################
# VPCs
#############################
resource "aws_vpc" "vpc" {
  cidr_block           = "172.33.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = local.tags
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_eip" "eip" {
  instance = aws_instance.web-server.id
  vpc      = true

  tags = local.tags
}

#############################
# Internet Gateways
#############################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags   = local.tags
}

resource "aws_route" "igw" {
  route_table_id         = aws_vpc.vpc.default_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

#############################
# Subnets
#############################
resource "aws_subnet" "subnet1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = data.aws_availability_zones.available.names[0]
  cidr_block        = cidrsubnet(aws_vpc.vpc.cidr_block, 8, 0)

  tags = merge(local.tags, { "Name" = "${local.tags.Name}-subnet1" })
}

#############################
# Security Groups
#############################
resource "aws_security_group" "sg1" {
  name        = "sg1"
  description = "sg1"
  vpc_id      = aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { "Name" = "${local.tags.Name}-sg1" })
}

resource "aws_security_group_rule" "web" {
  for_each          = toset(["80", "443"])
  type              = "ingress"
  from_port         = each.key
  to_port           = each.key
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sg1.id
}

resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sg1.id
}

#############################
# VMs
#############################
#data "aws_ami" "ubuntu_focal" {
#  owners      = ["099720109477"] ### will need to check if this is needed or not.
#  most_recent = true
#  filter {
#    name   = "name"
#    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
#  }
#}

resource "aws_instance" "web-server" {
  ami                         = var.ubuntu-ami
  instance_type               = var.instance_type
  #ebs_optimized               = true
  availability_zone           = data.aws_availability_zones.available.names[0]
  iam_instance_profile        = var.instance_profile
  subnet_id                   = aws_subnet.subnet1.id
  vpc_security_group_ids      = [aws_security_group.sg1.id]
  associate_public_ip_address = true
  key_name                    = var.key_pair
  user_data                   = local.cloudinit_config

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    delete_on_termination = true
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = local.tags
}

#############################
# Buckets
#############################
resource "aws_s3_bucket" "c-one-demo" {
  bucket = var.bucket_name
  force_destroy = true

  #server_side_encryption_configuration {
  #  rule {
  #    apply_server_side_encryption_by_default {
  #      sse_algorithm = "AES256"
  #    }
  #  }
  #}
}
resource "aws_s3_bucket_acl" "c-one-demo_bucket_acl" {
    bucket = aws_s3_bucket.c-one-demo.id
    acl    = "private"
}

# Upload an 
resource "aws_s3_object" "object" {

  bucket = aws_s3_bucket.c-one-demo.id
  key    = "top_secret_file"
  #acl    = aws_s3_bucket_acl.c-one-demo_bucket_acl  # or can be "public-read"
  source = "top_secret_file.csv"
  etag = filemd5("top_secret_file.csv") 
}

### Find how it is possible to copy file to the bucket or I could do it manually. 

#############################
# Outputs
#############################
output "public_ip" {
  value = aws_eip.eip.public_ip
}

output "instance_id" {
  value = aws_instance.web-server.id
}

output "bucket_name" {
  value = aws_s3_bucket.c-one-demo.id
}

