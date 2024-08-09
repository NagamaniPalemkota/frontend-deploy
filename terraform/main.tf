module "frontend_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"

  name = "${var.project_name}-${var.environment}-${var.common_tags.component}"

  instance_type          = "t3.micro"
  vpc_security_group_ids = [data.aws_ssm_parameter.frontend_sg_id.value]
  #convert stringlist to list and fetch 1st subnet id
  subnet_id              = local.public_subnet_id
  ami = data.aws_ami.ami_info.id

  tags = merge(
    var.common_tags,
    {
        Name = "${var.project_name}-${var.environment}-${var.common_tags.component}"
    }
  )
}
resource "null_resource" "resources" {
    triggers = {
        instance_id = module.frontend_instance.id #this will be triggered everytime, the instance is created

    }
    connection {
      type = "ssh"
      user = "ec2-user"
      password = "DevOps321"
      host = module.frontend_instance.private_ip
    }
    provisioner "file" {  #to copy a file to remote server, we use file provisioner after giving the connection details
      source = "${var.common_tags.component}.sh"
      destination = "/tmp/${var.common_tags.component}.sh"
    }
    provisioner "remote-exec" {
        inline =[
          "chmod +x /tmp/${var.common_tags.component}.sh",
          "sudo sh /tmp/${var.common_tags.component}.sh ${var.common_tags.component} ${var.environment} ${var.app_version}"

    ]
    }

}

#stopping the frontend instance before taking ami
resource "aws_ec2_instance_state" "frontend" {
    instance_id = module.frontend_instance.id
    state = "stopped"

    #stop the frontend resource only when the null resource provisioning is completed
    depends_on = [ null_resource.resources ]
}

#taking the AMI after stopping the configured frontend instance
resource "aws_ami_from_instance" "frontend" {
  name               = "${var.project_name}-${var.environment}-${var.common_tags.component}"
  source_instance_id = module.frontend_instance.id

#should take AMI only when instance is stopped
  depends_on = [ aws_ec2_instance_state.frontend ]
}

#configuring the resources using null resource
resource "null_resource" "frontend_delete" {
    triggers = {
        instance_id = module.frontend_instance.id #this will be triggered everytime, the instance is created

    }
    #not required for local-exec
    # connection {
    #   type = "ssh"
    #   user = "ec2-user"
    #   password = "DevOps321"
    #   host = module.frontend_instance.public_ip
    # }
    
    provisioner "local-exec" {
        command = "aws ec2 terminate-instances --instance-ids ${module.frontend_instance.id}"
    }
    depends_on = [ aws_ami_from_instance.frontend ]
}

#creates app lb providing the port and protocols, also the health check
resource "aws_lb_target_group" "frontend" {
  name        = "${var.project_name}-${var.environment}-${var.common_tags.component}"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value
  health_check {
    path = "/"
    port        = 80
    protocol    = "HTTP"
    healthy_threshold = 2
    unhealthy_threshold = 2
    matcher = "200-299"
  }
}

#creates an aws launch template with the AMI provided
resource "aws_launch_template" "frontend" {
  name = "${var.project_name}-${var.environment}-${var.common_tags.component}"

  image_id = aws_ami_from_instance.frontend.id

  instance_initiated_shutdown_behavior = "terminate"

  instance_type = "t3.micro"

  vpc_security_group_ids = [data.aws_ssm_parameter.frontend_sg_id.value]
  update_default_version = true #sets the latest version as default

  tag_specifications {
    resource_type = "instance"

    tags = merge(var.common_tags,{
      Name = "${var.project_name}-${var.environment}-${var.common_tags.component}"
    }
    )
  }
}

#creates an auto scaling group providing the launch template and defining the health checks, also mentions how many should be created at once
resource "aws_autoscaling_group" "frontend" {
  name                      = "${var.project_name}-${var.environment}-${var.common_tags.component}"
  max_size                  = 5
  min_size                  = 1
  health_check_grace_period = 60
  health_check_type         = "ELB"
  desired_capacity          = 1
  target_group_arns = [aws_lb_target_group.frontend.arn]
  launch_template {
    id = aws_launch_template.frontend.id
    version = "$Latest"
  }
  vpc_zone_identifier       = [local.public_subnet_id]

 tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-${var.common_tags.component}"
    propagate_at_launch = true
  }

  timeouts {
    delete = "15m"
  }
  tag {
    key                 = "Project"
    value               = "${var.project_name}"
    propagate_at_launch = true
  }
   instance_refresh {
    strategy = "Rolling" #it means new instance is created and then, old one is deleted.
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"] #refresh should be done when launch_template is updated
  }
}

# creates auto scaling policy, in which we define the metric based on which auto scaling has to be done
resource "aws_autoscaling_policy" "frontend" {
  name                   = "${var.project_name}-${var.environment}-${var.common_tags.component}"
  policy_type             = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.frontend.name

   target_tracking_configuration { #to be used whenn we specify policy_type as above, since we're tracking AVG cpu utilization
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 70.0
  }
}

# creating listener rule for web alb
resource "aws_lb_listener_rule" "frontend" {
  listener_arn = data.aws_ssm_parameter.web_alb_listener_arn_https.value
  priority     = 100 # can set multiple rules with respective priority numbers and the rule with less number gets prioritised

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  condition {
    host_header {
      values = ["web-${var.environment}.${var.zone_name}"] #we're providing the host path of backend
    }
  }
}