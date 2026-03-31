# -----------------------------------------------------------------------------
# VPC and private subnets (created before RDS / security groups)
# -----------------------------------------------------------------------------
# Two private subnets in different AZs are required for the RDS subnet group.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "cicd-pipeline-vpc"
  }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "cicd-pipeline-private-${count.index + 1}"
    Tier = "private"
  }
}

# Private subnets: VPC local traffic only (no NAT). RDS does not need outbound internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "cicd-pipeline-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
