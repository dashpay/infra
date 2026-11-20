# account

What belongs to the AWS account `dashdev` (`854439639386`) as a whole and to
no single service. Everything here existed before this repository and was
adopted with `imports.tf`.

## What is here

| File | What |
|---|---|
| `state-bucket.tf` | The bucket `dash-terraform-state-854439639386` (`us-east-1`) that holds every stack's state: versioning, encryption, public-access block, object ownership. It has no bucket policy and no lifecycle rule |
| `github-oidc.tf` | The GitHub Actions identity provider (`token.actions.githubusercontent.com`). Every deploy role in the other stacks trusts it |
| `iam-users.tf` | The users `daniel`, `quantum`, `vivek` and `gitlab-runner`, the AWS-managed policies attached to them and their inline policies |
| `iam-groups.tf` | The group `kops` (no members) and its five AWS-managed policies |
| `iam-account.tf` | The account alias `dashdev` and the password policy |
| `ipam.tf` | The IPAM `org-ipam` (home region `us-east-1`), the pools `byoip-top-level` and `byoip-us-west-2`, and the owned block `68.67.122.0/24` provisioned in each |

Other stacks do not read this stack's state. They look these things up:
the identity provider by URL, the address pool by its description
(`byoip-us-west-2`; the pool has no `Name` tag). Both lookups are written out
in the comments of `github-oidc.tf` and `ipam.tf`.

## What is not here

- **Access keys, console passwords, MFA devices.** Secrets, or the person's
  own. They are made by hand and never reach the state.
- **The service users** `backup-wp2021`, `backup-forum2023` (stack
  `storage`) and `wordpress-media` (stack `web`).
- **Elastic IPs.** Each belongs to the stack of the host that uses it.
- **The IPAM's default scopes, its default resource discovery and the
  association between them.** AWS makes and removes them with the IPAM;
  Terraform cannot create them.
- **The IPAM delegation.** `dashdev` is the Organization's delegated IPAM
  administrator. That is set in the management account (`103738324493`),
  not in this one.
- **Customer-managed IAM policies.** The account has eight. No user and no
  group here uses any of them. Four are attached to roles
  (`ECR_Access_policy` to `EC2-S3-Full`, `flow-logs-policy`, and two under
  `service-role/` for the Lambda `killdate`) and go with those roles; four
  are attached to nothing (`ForceMFA`, `S3BackupCowboy`, `DashDev-Packer`,
  `AWSLambdaEdgeExecutionRole-1772726a-…`).
- **Roles.** Each is in the stack of the thing that assumes it.
- **The root user** and its MFA device.
- **A RAM share of the pools.** None exists; the pools are used in this
  account only.

## What an operator must know

- **Terraform runs as `daniel`, and `daniel` is defined here.** Removing
  that user or its `AdministratorAccess` attachment locks Terraform out.
  Recovery is then by the root user.
- **Nothing in `ipam.tf` may be replaced or destroyed.** 127 Elastic IPs
  were allocated from the pool on 2026-11-20, 121 of them attached, mainnet
  services among them. All five resources carry `prevent_destroy`. If a plan
  ever fails on that guard, stop and find out why; do not remove the guard.
- **User tags are ignored.** The IAM console stores each access key's
  description as a tag on the user, named after the key's id. Keys are not
  managed here, so their descriptions are not either.
- **The first plan after import shows nine resources "updated in-place".**
  Eight of them gain the three default tags and nothing else. The four
  users also show `force_destroy = false`: that is a setting Terraform keeps
  in its own state, and no call to AWS is made for it.
- **Removing a user from `iam-users.tf` deletes the user.** AWS refuses
  while the user still has keys, a password or an MFA device. Remove those
  by hand first.
- The bucket also holds states from before this layout:
  `dash-infra/terraform.tfstate` (the `services` stack before the split) and
  `quorum-list-server/{base,testnet,mainnet}/terraform.tfstate` (applied
  from `dashpay/quorum-list-server`).

## Rebuild from nothing

"Nothing" means the account exists and a person can sign in with full
rights (the root user, or an administrator made by hand), and none of the
resources here do.

Delete `imports.tf` first. Then, in this order:

### 1. The state bucket

This stack keeps its state in the bucket it creates, so the first apply
cannot use that bucket.

1. Put a file `backend_override.tf` beside `versions.tf` (the name is
   git-ignored):

   ```hcl
   terraform {
     backend "local" {}
   }
   ```

2. `terraform init`, then apply only the bucket:

   ```sh
   terraform apply \
     -target=aws_s3_bucket.state \
     -target=aws_s3_bucket_versioning.state \
     -target=aws_s3_bucket_server_side_encryption_configuration.state \
     -target=aws_s3_bucket_public_access_block.state \
     -target=aws_s3_bucket_ownership_controls.state
   ```

3. Delete `backend_override.tf` and run `terraform init -migrate-state`.

**Lost:** every state object and all their versions. There is no second
copy of this bucket. Without the states nothing in AWS stops working, but
each stack must be adopted again: restore its `imports.tf` from git history
and apply. In a different account the bucket's name changes (it ends in the
account id), and with it the `backend` block of every stack.

### 2. IAM and the identity provider

```sh
terraform apply \
  -target=aws_iam_openid_connect_provider.github \
  -target=aws_iam_account_alias.this \
  -target=aws_iam_account_password_policy.this \
  -target=aws_iam_user.this \
  -target=aws_iam_user_policy_attachment.this \
  -target=aws_iam_user_policy.vivek_offboarding_deny \
  -target=aws_iam_user_policy.gitlab_runner_ecr_login \
  -target=aws_iam_user_policy.gitlab_runner_s3_cache \
  -target=aws_iam_group_policy_attachment.kops
```

Terraform recreates the provider, the alias, the password policy, the four
users with their policies, and the group. In the same account the provider
gets the same ARN, so role trust policies that name it stay valid.

By hand afterwards, because Terraform does not hold them:

| What | Who had it on 2026-11-20 | How |
|---|---|---|
| Access keys | `daniel` (two active), `quantum` (one, never used), `gitlab-runner` (one active, one inactive) | `aws iam create-access-key`, then put the new key wherever the old one was used. For `gitlab-runner` that is the CI's variables; this repository does not record where |
| Console passwords | `daniel`, `quantum` | `aws iam create-login-profile` with a password reset required |
| MFA | `daniel` (virtual device) | The person enrols a new device after signing in |

**Lost:** the key descriptions kept as user tags. A recreated user has a new
internal id; nothing known refers to it.

### 3. The IPAM and the address block

This part cannot be done by Terraform alone, and it is the slowest.

What has to be true outside AWS, at ARIN, where the block is registered
(`NET-68-67-122-0-1`, organisation `DCG-71`, Dash Core Group, Inc.):

- **A ROA** that lets Amazon's AS16509 originate `68.67.122.0/24`. One
  existed on 2026-11-20. It lives at ARIN and survives the loss of the
  account.
- **An X.509 certificate in the block's public comments.** One was there on
  2026-11-20. AWS checks the authorisation message below against it.
- **The private key of that certificate.** It signs the message. This
  repository does not know where the key is kept. If it is lost, make a new
  key and certificate and replace the certificate in ARIN's record, which
  needs a sign-in to ARIN Online for `DCG-71`.

AWS will not provision a block that is still provisioned somewhere else. If
the old IPAM or account still holds it, it must be withdrawn and
deprovisioned there first.

Then:

1. Write the authorisation message and sign it with the private key, as
   described in the AWS documentation for bringing your own addresses to
   IPAM. The message names the account id, the block and an expiry date, so
   a new one is needed every time.
2. Add it to `aws_vpc_ipam_pool_cidr.top_level` in `ipam.tf` for this one
   apply:

   ```hcl
   cidr_authorization_context {
     message   = "1|aws|854439639386|68.67.122.0/24|YYYYMMDD|SHA256|RSAPSS"
     signature = "…"
   }
   ```

3. `terraform apply`. It creates the IPAM, both pools, and provisions the
   block into each. AWS may take longer to provision an owned block than
   Terraform waits; if the apply times out, wait until the block shows as
   provisioned and apply again.
4. Take the `cidr_authorization_context` block out again. The resource
   ignores the difference.
5. Announce the block. Terraform has no resource for this:

   ```sh
   aws ec2 advertise-byoip-cidr --region us-west-2 --cidr 68.67.122.0/24
   ```

6. Apply the other stacks. Their Elastic IPs are allocated again from the
   pool. An Elastic IP can ask for a specific address of the pool
   (`address` beside `ipam_pool_id` on `aws_eip`), so a host can get back
   the address that DNS already points at. That has not been tried from
   this repository.

The IPAM and the pools get new ids. Stacks that find the pool by its
description follow by themselves; anything that names a pool id does not.

**Lost:** nothing that cannot be made again, as long as the registration at
ARIN and a usable signing key exist. Until step 6 is done every public
address of the account is gone, mainnet services included.

The IPAM delegation is restored from the Organization's management account
and is not needed for the pool to work in this account.

### Order across stacks

`account` first, then `dns`, then the rest.
