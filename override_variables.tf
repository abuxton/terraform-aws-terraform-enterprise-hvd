variable "template_file" {
  type    = string
  default = "tfe_user_data.sh.tpl"
  validation {
    condition     = can(fileexists("../../templates/${var.template_file}") || fileexists("./templates/${var.template_file}"))
    error_message = "File `./templates/${var.template_file}` not found or not readable"
  }
}


# variable "container_runtime" {
#   type        = string
#   description = "Container runtime to use for TFE. Supported values are 'docker' or 'podman'."
#   default     = "docker"

#   validation {
#     condition     = contains(["podman", "docker"], var.container_runtime)
#     error_message = "Supported values are `docker` or `podman`."
#   }
# }
