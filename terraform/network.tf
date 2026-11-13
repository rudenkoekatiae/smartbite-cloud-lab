# ─────────────────────────────────────────────────────────────────────────────
# Мережа: VPC у двох зонах доступності, три рівні підмереж.
#   public — балансувальник і NAT-шлюз (єдине, що має маршрут з інтернету);
#   app    — контейнери застосунку (приватна, вихід назовні тільки через NAT);
#   db     — база даних (приватна, взагалі без маршруту в інтернет).
# ─────────────────────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # ALB і RDS subnet group вимагають щонайменше дві зони доступності.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.project_name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.project_name }
}

# ── Підмережі ────────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.0.0.0/24, 10.0.1.0/24

  tags = { Name = "${var.project_name}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "app" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + count.index) # 10.0.10.0/24, 10.0.11.0/24

  tags = { Name = "${var.project_name}-app-${local.azs[count.index]}" }
}

resource "aws_subnet" "db" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + count.index) # 10.0.20.0/24, 10.0.21.0/24

  tags = { Name = "${var.project_name}-db-${local.azs[count.index]}" }
}

# ── Публічні підмережі: маршрут за замовчуванням через Internet Gateway ──────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(local.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── NAT: вихід у інтернет для приватних підмереж застосунку ──────────────────
# Контейнерам потрібен вихідний доступ, щоб завантажити образ з ECR, прочитати
# секрет із SSM і писати логи. Вхідні з'єднання з інтернету через NAT неможливі.
# Один NAT на обидві зони — компроміс заради вартості (для продакшену — по одному на зону).

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-nat" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = var.project_name }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project_name}-app" }
}

resource "aws_route_table_association" "app" {
  count = length(local.azs)

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

# ── Підмережі бази: лише локальний маршрут усередині VPC ─────────────────────

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-db" }
}

resource "aws_route_table_association" "db" {
  count = length(local.azs)

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}
