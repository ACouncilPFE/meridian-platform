output "state_machine_arn" {
  value = aws_sfn_state_machine.drill.arn
}

output "verify_lambda_arn" {
  value = aws_lambda_function.verify.arn
}
