variable "template_file" {
  type    = string
  default = ""
  validation {
    condition     = can(fileexists("../../templates/${var.template_file}") || fileexists("./templates/${var.template_file}"))
    error_message = "File `./templates/${var.template_file}` not found or not readable"
  }
}
variable "tfe_release_sequence" {
  type        = number
  description = "TFE release sequence number within Replicated. This specifies which TFE version to install for an `online` install. Ignored if `airgap_install` is `true`."
  default     = 776
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
