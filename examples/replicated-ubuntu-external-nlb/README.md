# Replicated deployment option

Please note this is not fully functional, it is purely to facilitate migration testing
the replicated deployment is best effort and set to external services.


## usage

The usage relies on the forked and reworked modules

```
module "terraform-enterprise-hvd" {
  # source = "../.."
  source = "git@github.com:abuxton/terraform-aws-terraform-enterprise-hvd.git?ref=abc-lab"

```

this introduces a template override;

```
variable "template_file" {
  type    = string
  default = "tfe_user_data.sh.tpl"
  validation {
    condition     = can(fileexists("../../templates/${var.template_file}") || fileexists("./templates/${var.template_file}"))
    error_message = "File `./templates/${var.template_file}` not found or not readable"
  }
}
```

This means you can add a `./templates` folder to your declaration and the module will pick up that template, the override in our case implements the replicated deployment option.

```

templates
└── override_tfe_user_data_replicated.sh.tpl
```

The code uses all the same prereqs as the standard module, it just expects your replicated license. The replicated license can be provided as follows; due to teh licenses binary format it is required to be base64 encoded, and the override expects this.

```
  #tfe_license_secret_value              = filebase64("./files/terraform.20241002.rli")
  #tfe_license_secret_name               = "tfe-replicated-license"
```

if you do this and wnat to also have a standard FDO license use `terraform state rm module.prereqs.aws_secretsmanager_secret.tfe_license\[0\]` on the prereqs before you then upload your fdo `*.hclic` has normal. ( unset `tfe_license_secret_name` or set it to something else at the very least)

### version

the variable `tfe_release_sequence` as been reintroduced for Replicated TFE versioning;
<https://developer.hashicorp.com/terraform/enterprise/releases>
release `776` is the last required release at time of writing, the default 764 is pre that for testing purposes.

```
variable "tfe_release_sequence" {
  type        = number
  description = "TFE release sequence number within Replicated. This specifies which TFE version to install for an `online` install. Ignored if `airgap_install` is `true`."
  default     = 764
}

## SSH

Addtional route to ssh to the host and use the provided output `instance_state_pubip` ( if you set the `ec2_subnet_ids` to public ips)

```
 ssh ubuntu@$(tf output -json instance_state_pubip | jq '. |= join( "" ) ') -i ~/.ssh/id_rsa
```


