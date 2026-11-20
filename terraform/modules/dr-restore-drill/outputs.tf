output "state_machine_arn" {
  value = aws_sfn_state_machine.drill.arn
}

output "verify_lambda_arn" {
  value = aws_lambda_function.verify.arn
}

output "verify_lambda_security_group_id" {
  description = "Allow this SG on 5432 into the Aurora security group (the drill cluster reuses it)."
  value       = aws_security_group.lambda.id
}
