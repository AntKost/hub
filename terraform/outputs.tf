output "hub_service_name" {
  description = "Name of the Hub ECS service"
  value       = aws_ecs_service.hub.name
}

output "hub_service_discovery_arn" {
  description = "ARN of the Hub Service Discovery service"
  value       = aws_service_discovery_service.hub.arn
}

output "hub_task_definition_arn" {
  description = "ARN of the Hub task definition"
  value       = aws_ecs_task_definition.hub.arn
}

output "hub_security_group_id" {
  description = "Security Group ID for Hub service"
  value       = aws_security_group.hub_sg.id
}

output "hub_ecr_repository_url" {
  description = "URL of the Hub ECR repository"
  value       = aws_ecr_repository.hub.repository_url
}

output "hub_ecr_repository_arn" {
  description = "ARN of the Hub ECR repository"
  value       = aws_ecr_repository.hub.arn
}

output "hub_ecr_policy_arn" {
  description = "ARN of the Hub ECR IAM policy"
  value       = aws_iam_policy.hub_ecr_policy.arn
}