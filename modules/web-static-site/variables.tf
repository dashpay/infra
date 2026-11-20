variable "key" {
  description = "Short name of the site. It is the site's prefix in the bucket and the end of its deploy role's name."
  type        = string
}

variable "hostname" {
  description = "The name the site is served at."
  type        = string
}

variable "zone_name" {
  description = "The Route 53 zone that holds the host name. Null when its DNS is somewhere Terraform does not manage; the output `dns_records` then lists what to make there by hand."
  type        = string
  default     = null
}

variable "bucket" {
  description = "The bucket that holds every site, one prefix each. Pass the aws_s3_bucket."
  type = object({
    arn                         = string
    bucket_regional_domain_name = string
  })
}

variable "origin_access_control_id" {
  description = "The origin access control CloudFront signs its requests to the bucket with."
  type        = string
}

variable "comment" {
  description = "The distribution's description."
  type        = string
}

variable "allowed_methods" {
  description = "HTTP methods the distribution accepts."
  type        = list(string)
  default     = ["GET", "HEAD"]
}

variable "deploy_repository" {
  description = "owner/name of the GitHub repository whose workflows publish the site. Null for a site nothing deploys: it gets no deploy role."
  type        = string
  default     = null
}

variable "deploy_role_description" {
  description = "Description of the deploy role, where it differs from the usual sentence."
  type        = string
  default     = null
}

variable "github_oidc_provider_arn" {
  description = "ARN of the account's token.actions.githubusercontent.com provider."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
