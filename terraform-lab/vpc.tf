########################################
# VPC
########################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.vpc_name
  }
}

########################################
# Public Subnet
########################################

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = local.public_subnet_name
  }
}

########################################
# Internet Gateway
########################################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = local.igw_name
  }
}

########################################
# Public Route Table
########################################

resource "aws_route_table" "public_rtb" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = local.public_rtb_name
  }
}

resource "aws_route_table_association" "public_association" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rtb.id
}


########################################
# Wazuh Security Group
########################################

resource "aws_security_group" "wazuh_sg" {
  name        = local.wazuh_sg_name
  description = "Wazuh manager"
  vpc_id      = aws_vpc.main.id

  # Wazuh agent communication
  ingress {
    description     = "Wazuh agent communication"
    from_port       = 1514
    to_port         = 1514
    protocol        = "tcp"
    security_groups = [aws_security_group.windows_sg.id]
  }

  # Wazuh agent enrollment
  ingress {
    description     = "Wazuh agent enrollment"
    from_port       = 1515
    to_port         = 1515
    protocol        = "tcp"
    security_groups = [aws_security_group.windows_sg.id]
  }

  # Wazuh API
  ingress {
    description     = "Wazuh API"
    from_port       = 55000
    to_port         = 55000
    protocol        = "tcp"
    security_groups = [aws_security_group.windows_sg.id]
  }

  # Dashboard
  ingress {
    description = "Wazuh dashboard"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.bad_actor_ip]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


########################################
# Windows Security Group
########################################

resource "aws_security_group" "windows_sg" {
  name        = "${local.sg_name}-windows"
  description = "Windows SOC endpoint"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
