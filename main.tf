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
  default = "c-demo-role"
}

variable "instance_policy" {
  default = "c-demo-policy"

}

variable "base_name" {
  default = "c-one-ssrf"
}

variable "bucket_name" {
  default = "c-one-demo"
}

variable "key_pair" {
  default = "shay-key"
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

#####################################
# Policy Roles and Instance Policy
#####################################
resource "aws_iam_policy" "demo-policy" {
  name        = var.instance_policy
  path        = "/"
  description = "c-demo policy"
  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "s3:*",
            "s3-object-lambda:*"
          ],
          "Resource" : "*"
        }
      ]
  })
}

resource "aws_iam_role" "demo-role" {
  name               = var.instance_profile
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "demo-attach" {
  role       = aws_iam_role.demo-role.name
  policy_arn = aws_iam_policy.demo-policy.arn
}

resource "aws_iam_instance_profile" "demo-profile" {
  name = var.instance_profile
  role = aws_iam_role.demo-role.name
}
#
##############################
# VMs
#############################

resource "aws_instance" "web-server" {
  ami           = var.ubuntu-ami
  instance_type = var.instance_type
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
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_acl" "acl" {
  bucket = aws_s3_bucket.c-one-demo.id
  acl    = "private"
}

# Upload the secret file
resource "aws_s3_object" "object" {
  bucket = aws_s3_bucket.c-one-demo.id
  key    = "top_secret_file"
  source = "top_secret_file.csv"
  etag   = filemd5("top_secret_file.csv")
}

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

