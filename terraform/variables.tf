variable "aws_region" {
  description = "The AWS region to deploy resources"
  type        = string
  default     = "eu-central-1"
}

variable "hub_image" {
  description = "Docker image for the Hub service"
  type        = string
  default     = "hub:latest"
}

variable "hub_cpu" {
  description = "CPU units for the Hub task"
  type        = string
  default     = "512"
}

variable "hub_memory" {
  description = "Memory (in MiB) for the Hub task"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Desired number of Hub service tasks"
  type        = number
  default     = 1
}

variable "service_name" {
  description = "Name of the Hub service"
  type        = string
  default     = "hub-service"
}

variable "container_port" {
  description = "Port on which the Hub container listens"
  type        = number
  default     = 8000
}

variable "host_port" {
  description = "Port on which the Hub host listens"
  type        = number
  default     = 8000
}

variable "hub_ecr_repository_name" {
  description = "Name of the ECR repository for the Hub service"
  type        = string
  default     = "hub-repo"
}

variable "image_tag_mutability" {
  description = "Image tag mutability setting"
  type        = string
  default     = "MUTABLE"
}

variable "encryption_configuration" {
  description = "Encryption settings for the ECR repository"
  type = object({
    encryption_type = string
    kms_key         = string
  })
  default = {
    encryption_type = "AES256"
    kms_key         = ""
  }
}