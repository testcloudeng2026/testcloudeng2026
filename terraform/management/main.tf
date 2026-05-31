data "aws_organizations_organization" "this" {}

resource "aws_organizations_organizational_unit" "dev" {
  name      = "dev"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "prod"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_account" "dev" {
  name      = "hello-platform-dev"
  email     = "testcloudeng2026+dev@gmail.com"
  parent_id = aws_organizations_organizational_unit.dev.id
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "prod" {
  name      = "hello-platform-prod"
  email     = "testcloudeng2026+prod@gmail.com"
  parent_id = aws_organizations_organizational_unit.prod.id
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [role_name]
  }
}
