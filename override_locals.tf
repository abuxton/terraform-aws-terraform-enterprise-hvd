locals {
  template_path = var.template_file == "" ? "${path.module}/templates/tfe_user_data.sh.tpl" : "${path.cwd}/templates/${var.template_file}"
}
