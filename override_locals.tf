locals {
  template_path = var.template_file == "" ? "${path.module}/templates/tfe_user_data.sh.tpl" : "${path.cwd}/templates/${var.template_file}"
  additional_user_data_args = {
    tfe_release_sequence = var.tfe_release_sequence
  }
  override_user_data_args = merge(local.user_data_args, local.additional_user_data_args)

}
