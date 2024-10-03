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

This means you can add a `./templates` folder to your decleration and the module will pick up that template, the override in our case impliments the replicated deployment option.

```

templates
└── override_tfe_user_data_replicated.sh.tpl
```

The code uses all the same prereqs as the standard module, it just expects your replicated license. The replicated license can be provided as follows; due to teh licenses binary format it is required to be base64 encoded, and the override expects this.

```
  #tfe_license_secret_value              = filebase64("./files/terraform.20241002.rli")
  #tfe_license_secret_name               = "tfe-replicated-license"
```
