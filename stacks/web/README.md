# web

Static sites, `media.dash.org`, the OpenAI proxy behind dashpay.io, and the
`chat.dash.org` redirect. Everything except `chat.dash.org` was moved here
from the dashevo account on 2026-11-20 (#19) and carries the tag
`Issue=dashpay/infra/19`.

## What is here

**Static sites** (`static-sites.tf`, `modules/web-static-site`). One private,
versioned bucket, `dash-static-sites-854439639386-usw2`, with one prefix per
site. CloudFront reads it through the origin access control
`dash-static-sites`. Each site has its own distribution and its own
certificate (ACM, `us-east-1`).

| Site | Prefix | DNS is in | Published by |
|---|---|---|---|
| `www.grovedb.org` | `grovedb/` | Route 53 `grovedb.org` | `dcginfra/grovedb-site` |
| `www.dashmate.org` | `dashmate/` | Route 53 `dashmate.org` | `dcginfra/dashmate-site` |
| `dashpay.io` | `dashpayio/` | Route 53 `dashpay.io` | `dashpay/data-contract-creator` |
| `proposal.dash.org` | `proposal/` | Cloudflare `dash.org` | `dashpay/proposal-generator` |
| `paper.dash.org` | `paper/` | Cloudflare `dash.org` | Nobody. Two files, uploaded by hand |

For the three sites in Route 53, Terraform also manages the alias records
(A and AAAA), the certificate's validation record and the `_<host>` TXT
record. That TXT record proved control of the name when it was moved between
accounts; nothing reads it now.

Each published site has a deploy role, `github-deploy-static-site-<prefix>`.
A workflow of the site's repository assumes it through GitHub OIDC. It can
write under its own prefix and invalidate its own distribution. The output
`sites` lists the five values each repository keeps in its Actions secrets.

**`media.dash.org`** (`media.tf`): the dash.org WordPress media library.
Bucket `dash-media-854439639386-usw2` (versioned; 15,862 objects, 2.1 GB on
2026-11-20), its distribution and certificate, and the IAM user
`wordpress-media` that WordPress on wp2021 uploads as.

**The OpenAI proxy** (`openai-proxy.tf`, source in `openai-proxy/`): the
Lambda function `dashpay-openai-api-proxy` (Node.js 22), its role, public
URL and log group. dashpay.io posts to the URL; the function adds the OpenAI
key and passes the request on.

**`chat.dash.org`** (`chat.tf`): a redirect to the Discord invite. An empty
website bucket in `us-east-1` holds the redirect rule, with a distribution
and a certificate in front.

## What is not here

| What | Where it is |
|---|---|
| DNS records of `paper`, `proposal`, `media` and `chat.dash.org` | Cloudflare zone `dash.org`, by hand. The output `dns_by_hand` lists what must be there |
| The zones `grovedb.org`, `dashmate.org`, `dashpay.io` | The `dns` stack. This stack looks them up by name |
| `grovedb.org` and `dashmate.org` without `www` | Records in the `dns` stack. They point at a host at DigitalOcean that redirects to `www` |
| The GitHub Actions OIDC provider | The `account` stack. Looked up by URL |
| The sites' content | The bucket. Published by the repositories above, not by Terraform |
| The access key of `wordpress-media` | Only in the WordPress option `tantan_wordpress_s3` on wp2021. Never in Terraform, so it is not in the state |
| The OpenAI key | SSM parameter `/grovedb-site/openai-key` (SecureString, `us-west-2`), made by hand. Terraform names it and never reads it |
| The repositories' secrets and workflows | Each repository |
| The `quorums.*.networks.dash.org` distributions | CloudFormation stacks (`quorums-cdn-*`). Not part of this stack |

## Rebuild from nothing

`account` (the OIDC provider) and `dns` (the zones) come first. If the zones
were recreated too, they have new name servers and the registrars must be
told before anything below resolves: at NameCheap, account `dashpay`, for
`grovedb.org`, `dashmate.org` and `dashpay.io` (the `dns` stack's README has
the steps).

1. **Put the OpenAI key back**: a SecureString parameter
   `/grovedb-site/openai-key` in `us-west-2` whose value is the key alone.
   The key comes from the OpenAI account; there is no other copy of it.
2. **Delete `imports.tf` and apply.** Terraform makes the buckets, the
   origin access control, seven certificates, the roles, the user, the
   function with its URL, and the Route 53 records that validate the three
   certificates there. **This first apply stops at the distributions**:
   CloudFront refuses a certificate that is not issued yet.
3. **At Cloudflare, by hand**: add the validation CNAME of the four
   certificates for `paper`, `proposal`, `media` and `chat.dash.org` (ACM
   shows each one, in `us-east-1`). DNS only, not proxied.
4. When ACM shows all seven certificates as issued, **apply again**.
   Terraform makes the seven distributions, the alias and TXT records in
   Route 53, and the deploy roles' policies.
5. **At Cloudflare, by hand**: point `paper`, `proposal`, `media` and
   `chat.dash.org` at their new distributions with a CNAME each (output
   `dns_by_hand`). DNS only, not proxied.
6. **Site content.** The bucket is empty.
   - In each of the four repositories set the secret
     `CLOUDFRONT_DISTRIBUTION_ID` to the new id (output `sites`). The other
     four secrets keep their values if the bucket and role names are
     unchanged. Then run the repository's deploy workflow.
   - `paper.dash.org`: no repository holds its two files (`index.html`,
     `paper.dash.org.html`). Copy them by hand into `paper/`. A copy is in
     the archive bucket of the `storage` stack, under
     `dash-dashevo-archive-854439639386-usw2/dashevo-infra/sites/paper/`.
7. **WordPress.** Make an access key for `wordpress-media` by hand and put
   it in the WP Offload Media settings on wp2021.
8. **The proxy has a new URL** (output `openai_proxy_url`). Write it into
   `src/services/openai.rs` in `dashpay/data-contract-creator` and deploy
   that site again.

What would be lost:

- **The media library**, if its bucket is lost. Nothing else holds those
  files: there is no replica and no backup of the bucket, and the old bucket
  in the dashevo account is being emptied. Versioning protects against a
  deleted or overwritten file, not against losing the bucket.
- Old versions of site files, and the function's logs.
- A deleted bucket's name is not free again at once, and both bucket names
  are written in the repositories' secrets and in the WordPress settings.

Not verified: three of the four deploy workflows (all but
`data-contract-creator`) have not run against these roles yet, and no
rebuild has been tried.

## Operating notes

- **To deploy a change to the proxy's code**, delete the `lifecycle` block
  in `openai-proxy.tf` once (the comment there says why it exists), then
  apply. Until then Terraform leaves the function's code alone.
- **To add a site**, add a row to `local.sites`. With `zone = null`, make
  its two records at Cloudflare from the output `dns_by_hand`, in the order
  of steps 3 to 5 above.
- **Certificates renew by themselves** as long as their validation CNAME
  exists. Four of those are at Cloudflare; do not tidy them away.
- The `_paper`, `_proposal` and `_media.dash.org` TXT records at Cloudflare
  are left from the move and can be deleted.
- On 2026-11-20 the OpenAI account answered "no credits remaining", so the
  AI feature of dashpay.io does not work until credits are added. That is
  not something this stack can fix.
- The lock file has the `hashicorp/archive` provider, which packs the
  function's source.
