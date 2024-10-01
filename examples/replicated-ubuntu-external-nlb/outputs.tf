#------------------------------------------------------------------------------
# TFE URLs
#------------------------------------------------------------------------------
output "tfe_url" {
  value = module.terraform-enterprise-hvd.tfe_url
}

output "tfe_lb_dns_name" {
  value = module.terraform-enterprise-hvd.lb_dns_name
}

#------------------------------------------------------------------------------
# Database
#------------------------------------------------------------------------------
output "rds_aurora_global_cluster_id" {
  value = module.terraform-enterprise-hvd.rds_aurora_global_cluster_id
}

output "rds_aurora_cluster_arn" {
  value = module.terraform-enterprise-hvd.rds_aurora_cluster_arn
}

output "rds_aurora_cluster_members" {
  value = module.terraform-enterprise-hvd.rds_aurora_cluster_members
}

output "rds_aurora_cluster_endpoint" {
  value = module.terraform-enterprise-hvd.rds_aurora_cluster_endpoint
}

#------------------------------------------------------------------------------
# Object storage
#------------------------------------------------------------------------------
output "tfe_s3_bucket_name" {
  value = module.terraform-enterprise-hvd.s3_bucket_name
}
