terraform {
  backend "s3" {
    bucket       = "shaurya-terraform-state-2026"
    key          = "terraform-lab/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
    encrypt      = true
  }
}
