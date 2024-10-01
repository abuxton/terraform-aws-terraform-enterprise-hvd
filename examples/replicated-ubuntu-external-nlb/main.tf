terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.59.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2" # change to your desired region
}

module "terraform-enterprise-hvd" {
  source = "../.."

  # --- Common --- #
  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = var.common_tags

  # --- Bootstrap --- #
  tfe_license_secret_arn             = var.tfe_license_secret_arn
  tfe_encryption_password_secret_arn = var.tfe_encryption_password_secret_arn
  tfe_tls_cert_secret_arn            = var.tfe_tls_cert_secret_arn
  tfe_tls_privkey_secret_arn         = var.tfe_tls_privkey_secret_arn
  tfe_tls_ca_bundle_secret_arn       = var.tfe_tls_ca_bundle_secret_arn

  # --- TFE configuration settings --- #
  tfe_fqdn      = var.tfe_fqdn
  tfe_image_tag = var.tfe_image_tag

  # --- Networking --- #
  vpc_id                     = var.vpc_id
  lb_subnet_ids              = var.lb_subnet_ids
  lb_is_internal             = var.lb_is_internal
  ec2_subnet_ids             = var.ec2_subnet_ids
  rds_subnet_ids             = var.rds_subnet_ids
  redis_subnet_ids           = var.redis_subnet_ids
  cidr_allow_ingress_tfe_443 = var.cidr_allow_ingress_tfe_443
  cidr_allow_ingress_ec2_ssh = var.cidr_allow_ingress_ec2_ssh

  # --- DNS (optional) --- #
  create_route53_tfe_dns_record      = var.create_route53_tfe_dns_record
  route53_tfe_hosted_zone_name       = var.route53_tfe_hosted_zone_name
  route53_tfe_hosted_zone_is_private = var.route53_tfe_hosted_zone_is_private

  # --- Compute --- #
  ec2_os_distro                 = var.ec2_os_distro
  ec2_ssh_key_pair              = var.ec2_ssh_key_pair
  asg_instance_count            = var.asg_instance_count
  asg_max_size                  = var.asg_max_size
  asg_health_check_grace_period = var.asg_health_check_grace_period
  template_file                 = var.template_file
  container_runtime             = var.container_runtime
  # --- Database --- #
  tfe_database_password_secret_arn = var.tfe_database_password_secret_arn
  rds_skip_final_snapshot          = var.rds_skip_final_snapshot

  # --- Redis --- #
  # tfe_redis_password_secret_arn = var.tfe_redis_password_secret_arn
}
data "aws_instances" "tfe_instances" {
  instance_state_names = ["running"]
}
output "instance_state_pubip" {
  description = "Instance Public IPs"
  value       = data.aws_instances.tfe_instances.public_ips
}
