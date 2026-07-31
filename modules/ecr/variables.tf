variable "prefix" {
  type    = string
  default = "bookstore"
}

variable "image_retention_count" {
  description = "Number of images to keep per repository"
  type        = number
  default     = 10
}

variable "secondary_region" {
  description = "Secondary AWS region for cross-region image replication. Empty string disables replication."
  type        = string
  default     = ""
}

variable "extra_repos" {
  description = "Additional short repo names (without prefix) to create, e.g. [\"catalog-service\"]"
  type        = list(string)
  default     = []
}
