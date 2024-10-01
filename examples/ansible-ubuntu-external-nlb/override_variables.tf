variable "template_file" {
  type    = string
  default = "tfe_user_data.sh.tpl"
  validation {
    condition     = can(fileexists("../../templates/${var.template_file}") || fileexists("./templates/${var.template_file}"))
    error_message = "File `./templates/${var.template_file}` not found or not readable"
  }
}
