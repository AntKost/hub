# Reference Shared Infra State
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket         = "rv-terraform-state-bucket"        # Replace with your S3 bucket name
    key            = "shared-infra/terraform.tfstate"    # Path to the shared infra state file
    region         = "eu-central-1"                      
    dynamodb_table = "terraform-locks"                   # DynamoDB table for state locking
    encrypt        = true
    profile = "rv-terraform"
  }
}

data "terraform_remote_state" "store" {
  backend = "s3"
  config = {
    bucket         = "rv-terraform-state-bucket"        # Replace with your S3 bucket name
    key            = "store/terraform.tfstate"    # Path to the shared infra state file
    region         = "eu-central-1"                      
    dynamodb_table = "terraform-locks"                   # DynamoDB table for state locking
    encrypt        = true
    profile = "rv-terraform"
  }
}

# Service Discovery Service for Hub
resource "aws_service_discovery_service" "hub" {
  name = "hub"

  dns_config {
    namespace_id = data.terraform_remote_state.shared.outputs.service_discovery_namespace_id

    dns_records {
      type = "A"
      ttl  = 60
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# Security Group for Hub Service
resource "aws_security_group" "hub_sg" {
  name        = "hub-sg"
  description = "Allow Hub traffic"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "hub-sg"
  }
}

# ECR Repository for Hub Service
resource "aws_ecr_repository" "hub" {
  name                 = var.hub_ecr_repository_name
  image_tag_mutability = var.image_tag_mutability

  encryption_configuration {
    encryption_type = var.encryption_configuration.encryption_type
    kms_key         = var.encryption_configuration.kms_key != "" ? var.encryption_configuration.kms_key : null
  }

  tags = {
    Name        = "hub-ecr-repository"
  }
}

# IAM Policy for ECR Push/Pull Access
resource "aws_iam_policy" "hub_ecr_policy" {
  name        = "hub-ecr-policy"
  description = "IAM policy for Hub service to access ECR repository"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = aws_ecr_repository.hub.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = aws_ecr_repository.hub.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach the ECR policy to the ECS Task Execution Role
resource "aws_iam_role_policy_attachment" "hub_ecr_attachment" {
  policy_arn = aws_iam_policy.hub_ecr_policy.arn
  role       = data.terraform_remote_state.shared.outputs.ecs_task_execution_role_arn
}

# Hub Task Definition
resource "aws_ecs_task_definition" "hub" {
  family                   = "hub"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = var.hub_cpu
  memory                   = var.hub_memory

  container_definitions = jsonencode([{
    name  = "hub"
    image = var.hub_image
    portMappings = [{
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
    }]
    environment = [
      {
        name  = "MQTT_BROKER_HOST"
        value = "${data.terraform_remote_state.shared.outputs.mqtt_service_discovery_name}.${data.terraform_remote_state.shared.outputs.ecs_cluster_name}.local"
      },
      {
        name  = "MQTT_BROKER_PORT"
        value = "1883"
      },
      {
        name  = "REDIS_HOST"
        value = "${data.terraform_remote_state.shared.outputs.redis_service_discovery_name}.${data.terraform_remote_state.shared.outputs.ecs_cluster_name}.local"
      },
      {
        name  = "REDIS_PORT"
        value = "6379"
      },
      {
        name  = "STORE_API_HOST"
        value = "${data.terraform_remote_state.store.outputs.store_service_discovery_name}.${data.terraform_remote_state.shared.outputs.ecs_cluster_name}.local"
      },
      {
        name  = "STORE_API_PORT"
        value = "8000"
      },
      {
        name  = "MQTT_TOPIC"
        value = "processed_data_topic"
      },
      {
        name  = "BATCH_SIZE"
        value = 1
      }
    ]
  }])

  execution_role_arn = data.terraform_remote_state.shared.outputs.ecs_task_execution_role_arn
}

# Hub ECS Service
resource "aws_ecs_service" "hub" {
  name            = "hub-service"
  cluster         = data.terraform_remote_state.shared.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.hub.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets         = data.terraform_remote_state.shared.outputs.public_subnet_ids
    security_groups = [aws_security_group.hub_sg.id, data.terraform_remote_state.shared.outputs.ecs_instance_security_group_id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.hub.arn
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  depends_on = [aws_service_discovery_service.hub, aws_ecs_task_definition.hub, aws_security_group.hub_sg]
}
