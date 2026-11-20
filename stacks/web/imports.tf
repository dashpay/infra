# Static sites: the shared bucket and its origin access control.

import {
  to = aws_s3_bucket.sites
  id = "dash-static-sites-854439639386-usw2"
}

import {
  to = aws_s3_bucket_versioning.sites
  id = "dash-static-sites-854439639386-usw2"
}

import {
  to = aws_s3_bucket_ownership_controls.sites
  id = "dash-static-sites-854439639386-usw2"
}

import {
  to = aws_s3_bucket_public_access_block.sites
  id = "dash-static-sites-854439639386-usw2"
}

import {
  to = aws_s3_bucket_policy.sites
  id = "dash-static-sites-854439639386-usw2"
}

import {
  to = aws_cloudfront_origin_access_control.sites
  id = "E2ZX1WS9GAHNS7"
}

# Static sites: each site's certificate (us-east-1) and distribution.

import {
  for_each = {
    grovedb   = "cf8018fb-4b8d-4084-bec7-6d089182b642"
    dashmate  = "00798b8c-5d29-441e-8e6d-9d98ae35489f"
    dashpayio = "ae6ccf6f-d0c3-42c1-9f2c-d1c7c5394dad"
    proposal  = "f7ab28e5-0bbb-46d4-9e12-b7e6eb4429c0"
    paper     = "2e1fb184-09a1-43d0-8d5f-c805ee849ab8"
  }

  to = module.site[each.key].aws_acm_certificate.this
  id = "arn:aws:acm:us-east-1:854439639386:certificate/${each.value}@us-east-1"
}

import {
  for_each = {
    grovedb   = "E1TEU6QEJW7TIP"
    dashmate  = "E1G66MP1KTDRC4"
    dashpayio = "E2OU1DCM733O3T"
    proposal  = "E3I7P0ZDQ4B5UT"
    paper     = "E1RS2GF9A35G8H"
  }

  to = module.site[each.key].aws_cloudfront_distribution.this
  id = each.value
}

# Static sites: the records of the three whose zone is in Route 53, as
# "<zone id>_<name>_<type>".

import {
  for_each = {
    grovedb   = "Z10323483BDUSECDK54BZ_www.grovedb.org"
    dashmate  = "Z05777733SJY8P7JLTXTI_www.dashmate.org"
    dashpayio = "Z10328341P85UO9LYIGM_dashpay.io"
  }

  to = module.site[each.key].aws_route53_record.alias["A"]
  id = "${each.value}_A"
}

import {
  for_each = {
    grovedb   = "Z10323483BDUSECDK54BZ_www.grovedb.org"
    dashmate  = "Z05777733SJY8P7JLTXTI_www.dashmate.org"
    dashpayio = "Z10328341P85UO9LYIGM_dashpay.io"
  }

  to = module.site[each.key].aws_route53_record.alias["AAAA"]
  id = "${each.value}_AAAA"
}

import {
  for_each = {
    grovedb   = "Z10323483BDUSECDK54BZ__97eafe04c66d9538e3422ec333509fb7.www.grovedb.org"
    dashmate  = "Z05777733SJY8P7JLTXTI__5319bc19272bcdab4149b3164cd355bf.www.dashmate.org"
    dashpayio = "Z10328341P85UO9LYIGM__e344f78c51acf55a5a1f96e7a55abcf6.dashpay.io"
  }

  to = module.site[each.key].aws_route53_record.validation[0]
  id = "${each.value}_CNAME"
}

import {
  for_each = {
    grovedb   = "Z10323483BDUSECDK54BZ__www.grovedb.org"
    dashmate  = "Z05777733SJY8P7JLTXTI__www.dashmate.org"
    dashpayio = "Z10328341P85UO9LYIGM__.dashpay.io"
  }

  to = module.site[each.key].aws_route53_record.proof[0]
  id = "${each.value}_TXT"
}

# Static sites: the deploy roles. An inline policy is "<role>:<policy>".

import {
  for_each = toset(["grovedb", "dashmate", "dashpayio", "proposal"])

  to = module.site[each.key].aws_iam_role.deploy[0]
  id = "github-deploy-static-site-${each.key}"
}

import {
  for_each = toset(["grovedb", "dashmate", "dashpayio", "proposal"])

  to = module.site[each.key].aws_iam_role_policy.deploy[0]
  id = "github-deploy-static-site-${each.key}:deploy"
}

# media.dash.org. The user's access key is deliberately not imported.

import {
  to = aws_s3_bucket.media
  id = "dash-media-854439639386-usw2"
}

import {
  to = aws_s3_bucket_versioning.media
  id = "dash-media-854439639386-usw2"
}

import {
  to = aws_s3_bucket_ownership_controls.media
  id = "dash-media-854439639386-usw2"
}

import {
  to = aws_s3_bucket_public_access_block.media
  id = "dash-media-854439639386-usw2"
}

import {
  to = aws_s3_bucket_policy.media
  id = "dash-media-854439639386-usw2"
}

import {
  to = aws_acm_certificate.media
  id = "arn:aws:acm:us-east-1:854439639386:certificate/56e8aaf0-c691-4ce2-a760-b4832190c787@us-east-1"
}

import {
  to = aws_cloudfront_distribution.media
  id = "ER8LZKMATFQP1"
}

import {
  to = aws_iam_user.wordpress_media
  id = "wordpress-media"
}

import {
  to = aws_iam_user_policy.wordpress_media
  id = "wordpress-media:media-bucket"
}

# The OpenAI proxy. The parameter that holds the key is deliberately not
# imported.

import {
  to = aws_lambda_function.openai_proxy
  id = "dashpay-openai-api-proxy"
}

import {
  to = aws_lambda_function_url.openai_proxy
  id = "dashpay-openai-api-proxy"
}

import {
  to = aws_lambda_permission.openai_proxy_url
  id = "dashpay-openai-api-proxy/public-url"
}

import {
  to = aws_lambda_permission.openai_proxy_invoke
  id = "dashpay-openai-api-proxy/public-url-invoke"
}

import {
  to = aws_cloudwatch_log_group.openai_proxy
  id = "/aws/lambda/dashpay-openai-api-proxy"
}

import {
  to = aws_iam_role.openai_proxy
  id = "dashpay-openai-api-proxy"
}

import {
  to = aws_iam_role_policy.openai_proxy
  id = "dashpay-openai-api-proxy:proxy"
}

# chat.dash.org (bucket and certificate in us-east-1).

import {
  to = aws_s3_bucket.chat
  id = "chat.dash.org@us-east-1"
}

import {
  to = aws_s3_bucket_website_configuration.chat
  id = "chat.dash.org@us-east-1"
}

import {
  to = aws_s3_bucket_public_access_block.chat
  id = "chat.dash.org@us-east-1"
}

import {
  to = aws_s3_bucket_policy.chat
  id = "chat.dash.org@us-east-1"
}

import {
  to = aws_acm_certificate.chat
  id = "arn:aws:acm:us-east-1:854439639386:certificate/2d1a8899-35ae-426b-9fd1-faf8351e72c1@us-east-1"
}

import {
  to = aws_cloudfront_distribution.chat
  id = "E14CVR9EWYIFCZ"
}
