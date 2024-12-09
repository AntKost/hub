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

  ingress {
    from_port       = var.host_port
    to_port         = var.host_port
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.shared.outputs.lb_sg_id]
    description     = "Allow HTTP traffic from NLB"
  }

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

# ALB Target Group for Hub Service
resource "aws_lb_target_group" "hub_tg_blue" {
  name        = "hub-tg-blue"
  port        = var.host_port
  protocol    = "TCP"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "hub-tg-blue"
  }
}

resource "aws_lb_target_group" "hub_tg_green" {
  name        = "hub-tg-green"
  port        = var.host_port
  protocol    = "TCP"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "hub-tg-green"
  }
}

# ALB Listener for Hub Service
resource "aws_lb_listener" "hub_listener" {
  load_balancer_arn = data.terraform_remote_state.shared.outputs.lb_arn
  port              = var.host_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hub_tg_blue.arn
  }

  tags = {
    Name = "hub-listener"
  }

  lifecycle {
    ignore_changes = [ default_action[0].target_group_arn ]
  }
}

resource "aws_lb_listener" "hub_listener_green" {
  load_balancer_arn = data.terraform_remote_state.shared.outputs.lb_arn
  port              = 9090
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hub_tg_green.arn
  }

  tags = {
    Name = "hub-listener"
  }

  lifecycle {
    ignore_changes = [ default_action[0].target_group_arn ]
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
  role       = data.terraform_remote_state.shared.outputs.ecs_task_execution_role_name
}

resource "aws_cloudwatch_log_group" "hub_log_group" {
  name              = "/ecs/hub"
  retention_in_days = 3
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
      hostPort      = var.host_port
      protocol      = "tcp"
    },
    {
      containerPort = 1883
      hostPort      = 1883
      protocol      = "tcp"
    }]
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 5
      startPeriod = 15
    }
    logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.hub_log_group.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
    }
    environment = [
      {
        name  = "STORE_API_HOST"
        value = "store.road-vision-cluster.local"
      },
      {
        name  = "STORE_API_PORT"
        value = "8001"
      },
      {
        name  = "REDIS_HOST"
        value = data.terraform_remote_state.shared.outputs.redis_endpoint
      },
      {
        name  = "REDIS_PORT"
        value = "6379"
      },
      {
        name  = "MQTT_BROKER_HOST"
        value = "mqtt.road-vision-cluster.local"
      },
      {
        name  = "MQTT_BROKER_PORT"
        value = "1883"
      },
      {
        name  = "MQTT_TOPIC"
        value = "processed_data_topic"
      },
      {
        name  = "BATCH_SIZE"
        value = "1"
      }
    ]
  }])

  execution_role_arn = data.terraform_remote_state.shared.outputs.ecs_task_execution_role_arn
  task_role_arn      = data.terraform_remote_state.shared.outputs.ecs_task_execution_role_arn
}

resource "aws_codedeploy_app" "hub" {
  name        = "hub-codedeploy-app"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "hub" {
  app_name              = aws_codedeploy_app.hub.name
  deployment_group_name = "hub-deployment-group"
  service_role_arn      = data.terraform_remote_state.shared.outputs.codedeploy_role_arn

  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  ecs_service {
    cluster_name = data.terraform_remote_state.shared.outputs.ecs_cluster_name
    service_name = aws_ecs_service.hub.name
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    terminate_blue_instances_on_deployment_success {
      action                              = "TERMINATE"
      termination_wait_time_in_minutes    = 5
    }

    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
      wait_time_in_minutes = 0
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  load_balancer_info {
    target_group_pair_info {
      target_group {
        name = aws_lb_target_group.hub_tg_blue.name
      }

      target_group {
        name = aws_lb_target_group.hub_tg_green.name
      }

      prod_traffic_route {
        listener_arns = [aws_lb_listener.hub_listener.arn]
      }
    }
  }
}

# Hub ECS Service
resource "aws_ecs_service" "hub" {
  name            = "hub-service"
  cluster         = data.terraform_remote_state.shared.outputs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.hub.arn
  desired_count   = 1
  
  capacity_provider_strategy {
    capacity_provider = data.terraform_remote_state.shared.outputs.asg_capacity_provider
    weight            = 1
    base              = 100
  }

  network_configuration {
    subnets         = data.terraform_remote_state.shared.outputs.public_subnet_ids
    security_groups = [aws_security_group.hub_sg.id, data.terraform_remote_state.shared.outputs.ecs_instances_sg_id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.hub.arn
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hub_tg_blue.arn
    container_name   = "hub"
    container_port   = var.container_port
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }
  
  depends_on = [aws_lb_listener.hub_listener]
}
