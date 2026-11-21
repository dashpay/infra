# dashnet-managed-state: the engine's record of every network.
#
# `dashnet` (dashpay/dash-network-go) keeps one item per network, keyed
# "<account>/<region>/<network>": which hosts belong to it, the plan that
# built or enrolled it, who holds it for an operation, and how far that
# operation got. The console reads it to know what it manages, and the
# engine refuses to act on a network whose item disagrees with what it
# finds. On 2026-11-20 it held 13 items: testnet, the live devnets and the
# records of destroyed ones.
#
# The engine does not create the table. It only checks that it exists. Its
# name is in the console's settings (`aws.stateTable`).
#
# LOSING IT: Terraform makes an empty table again, not the items. Point-in-
# time recovery is OFF, there is no backup and deletion protection is off.
# README.md, "Rebuild from nothing", says what an empty table means for each
# network.

resource "aws_dynamodb_table" "managed_state" {
  name         = "dashnet-managed-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "Network"

  attribute {
    name = "Network"
    type = "S"
  }


  lifecycle {
    prevent_destroy = true
  }
}
