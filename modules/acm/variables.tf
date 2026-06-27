variable "domain_name" {
  description = "Primary domain name for the ACM certificate"
  type        = string
}

variable "san_names" {
  description = "Subject Alternative Names (e.g. [\"*.example.com\"])"
  type        = list(string)
  default     = []
}
