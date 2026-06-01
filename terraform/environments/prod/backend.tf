terraform {
  required_providers {
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "hello-platform-tfstate-977145922427"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:977145922427:key/e91d26d8-108f-4880-a270-eb5488e72930"
    dynamodb_table = "hello-platform-tfstate-lock"
  }
}
