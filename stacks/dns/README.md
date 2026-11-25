# dns

The public DNS zones in Route 53, the records in them that belong to no
other stack, and the domain registrations held in this account.

## What is here

**Zones** (`zones.tf`). All eight are protected against destroy.

| Zone | Who points at its name servers | Records managed here |
|---|---|---|
| `networks.dash.org` | Cloudflare zone `dash.org`: four NS records, by hand | None, on purpose (see below) |
| `subscribe.dash.org` | Cloudflare zone `dash.org`: four NS records, by hand | `sg.subscribe.dash.org` and its certificate's validation record |
| `dash-devnets.org` | Its registration, in this account | None. The zone is empty |
| `dashevo.org` | Its registration, in this account | Two certificate validation records |
| `dashtalk.org` | Its registration, in this account | `dashtalk.org`, `www.dashtalk.org` |
| `dashmate.org` | NameCheap, account `dashpay`, by hand | `dashmate.org`, two old validation records |
| `grovedb.org` | NameCheap, account `dashpay`, by hand | `grovedb.org`, one old validation record |
| `dashpay.io` | NameCheap, account `dashpay`, by hand | `invitations.dashpay.io`, one old validation record |

**Records** (`records.tf`): 13, in one table with a note on what each is for.

**Registrations** (`domains.tf`): `dash-devnets.org`, `dashevo.org`,
`dashtalk.org` and `dashforum.org`, registered with Route 53 Domains in this
account. Auto-renew, transfer lock and contact privacy are on for all four.
The first three take their name servers from the zone here. `dashforum.org`
points at Cloudflare (`angela` and `owen.ns.cloudflare.com`), where its
records are.

## What is not here

| What | Where it is |
|---|---|
| `services.dash.org` | The `services` stack |
| Records of `networks.dash.org` | The stacks that own what they name (`quorum`, `network-services`), the retired `dash-network-deploy` states, hand-made records, and the status console, which adds and removes devnet names while it runs. Declaring them here would make Terraform fight the console |
| The sites' records in `grovedb.org`, `dashmate.org`, `dashpay.io`: alias, certificate validation, `_<host>` TXT | The `web` stack, beside each site |
| `insight.dashevo.org` and its certificate's validation record | The `network-services` stack |
| Private zones `internal.` and `dcg.internal.` | A CloudFormation stack from 2019 (`Route53`) and the state of the idle runner Terraform. Not adopted |
| `dash.org` and every other zone at Cloudflare, including the records of `dashforum.org` | Cloudflare, by hand. Terraform here does not manage Cloudflare |
| The registrations of `dashmate.org`, `grovedb.org`, `dashpay.io` (and `dash.org`) | NameCheap, account `dashpay`. Their renewal is not visible from here |
| The registrations' contact details | The registry. They are not written in this repository |
| NS and SOA records at the top of each zone | Part of the zone; Route 53 makes them |
| What `sg.subscribe.dash.org` points at (an API Gateway domain, the API `sendgrid-api`) and the unused certificate `*.dashevo.org` | Made by hand, in no stack |

## Rebuild from nothing

Order: `account`, then this stack, then the others.

1. Delete `imports.tf` and apply. Terraform makes the eight zones and the 13
   records. It does not register domains: it takes over the four
   registrations as they are, which works as long as they still exist in
   this account's Route 53 Domains.
2. **Every recreated zone has four new name servers.** The output
   `name_servers` lists them. Nothing resolves until whoever delegates to
   the zone has been told:
   - `dash-devnets.org`, `dashevo.org`, `dashtalk.org`: nothing to do. The
     same apply writes the new name servers to the registry.
   - `networks.dash.org`, `subscribe.dash.org`: in the Cloudflare zone
     `dash.org`, replace the four NS records of each name by hand.
   - `dashmate.org`, `grovedb.org`, `dashpay.io`: at NameCheap, account
     `dashpay`, set the four name servers of each domain by hand (dashboard
     or API).
3. Apply the other stacks. `web` and `network-services` look these zones up
   by name and put their own records back.

What Terraform cannot bring back:

- **The records of `networks.dash.org`** that no stack declares. The zone
  had 61 record sets on 2026-11-20, most of them hand-made or from the
  retired network tooling, and they include mainnet names
  (`seed-1` to `seed-4.mainnet`, `rpc-mainnet`, `fullnode.mainnet`). Nothing
  exports that zone. The console writes a devnet's names only when it
  deploys that devnet.
- **A lost registration.** If a domain has left the account (expired,
  transferred, account closed), Terraform cannot get it back.
- The contents of the zones at Cloudflare and the registrations at
  NameCheap, which were never here.

## Operating notes

- **A record added by hand does not show up in a plan.** Terraform only
  knows the records in `records.tf`. Add it there.
- **Changing a name server in `domains.tf` changes the delegation at the
  registry at once.** Destroying a registration resource only makes
  Terraform forget it; the domain stays registered.
- **The state holds the registrations' contact details**, and a plan that
  touches a registration prints them (name, address, phone, e-mail). The
  provider reads them whether or not they are in the configuration. Do not
  paste such a plan into a pull request or a public log.
- The registrations run to 2027 (`dash-devnets.org` and `dashforum.org`
  05-03, `dashevo.org` 05-22, `dashtalk.org` 12-23, UTC) and renew by
  themselves.
- Until 2026-11-22 18:00 UTC the old copies of `dashevo.org`,
  `dashtalk.org`, `dashmate.org`, `dashpay.io` and `grovedb.org` still exist
  in the dashevo account. Nothing is delegated to them any more, but a
  record changed here before then should be changed there too, in case the
  move is undone.
- The addresses behind `dashtalk.org`, `dashmate.org` and `grovedb.org` are
  hosts at DigitalOcean that only redirect. This stack does not know who
  runs them.
