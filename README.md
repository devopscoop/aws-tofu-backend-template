# OpenTofu remote-state bucket template

Creates one S3 bucket to hold the OpenTofu remote state for one git
repository. Copy this directory into a repo (conventionally as
`bootstrap/`), run the two-phase procedure below, and the repo has a
dedicated, hardened state bucket that is itself managed as code.

Requires OpenTofu >= 1.10 (uses S3-native locking via `use_lockfile`,
so no DynamoDB table is needed).

What the bucket gets:

- **Versioning** — every state write is recoverable; this is the safety
  net for a corrupted or accidentally deleted state file.
- **SSE-KMS encryption at rest** with a dedicated customer-managed KMS
  key per repo, automatic annual rotation enabled (~$1/month per key).
  Reading state requires `kms:Decrypt` on the key in addition to
  `s3:GetObject`, and key usage is logged in CloudTrail.
- **TLS-only access** enforced by bucket policy; **all public access
  blocked.**
- **Optional access logging** — set `access_log_bucket` to a central,
  org-level log bucket and every read/write of state is recorded. Create
  that log bucket (or account-wide CloudTrail S3 data events) once,
  outside this per-repo template.
- **`prevent_destroy`** on both the bucket and the KMS key — `tofu
  destroy` refuses to delete the state or the key that decrypts it
  unless you deliberately remove the guards.
- **Lifecycle rule** expiring noncurrent state versions after 90 days
  (configurable) so versioning doesn't accumulate cost forever.

## Bootstrap procedure

### Phase 1 — create the bucket with local state

```sh
tofu init
tofu apply -var repo_name=<repo-name>          # add -var region=... if not us-east-1
```

The `backend.tf` block is commented out at this point, so state lands in
a local `terraform.tfstate`. The bucket is named
`<repo_name>-tfstate-<account_id>` unless you override `bucket_name`.

### Phase 2 — migrate the state into the bucket it just created

```sh
tofu output state_bucket                        # bucket name
tofu output state_kms_key_arn                   # KMS key ARN
```

Uncomment the `terraform { backend "s3" { ... } }` block in `backend.tf`,
fill in the bucket name and KMS key ARN (and region if changed), then:

```sh
tofu init -migrate-state
rm terraform.tfstate terraform.tfstate.backup   # local copy is now redundant
```

Commit everything. The bootstrap config's own state now lives at
`bootstrap/terraform.tfstate` inside the bucket it manages.

### Phase 3 — point the repo's real configuration at the bucket

```sh
tofu output backend_config
```

Paste that block into the repo's main root module and `tofu init`. Use a
distinct `key` per root module (the bootstrap state uses
`bootstrap/terraform.tfstate`; the main config uses `terraform.tfstate`
by default). One bucket per repo, many keys, is fine — the rule this
template enforces is no bucket shared *across* repos.

## Access notes

- Any principal that runs `tofu plan`/`apply` against this backend needs
  `kms:Decrypt` and `kms:GenerateDataKey` on the state key, in addition
  to the usual S3 permissions on the bucket.
- `kms_key_id` in the backend block is not optional decoration: with
  `encrypt = true` alone, the backend requests SSE-S3 per object, which
  overrides the bucket's default KMS encryption. Setting `kms_key_id` is
  what makes the state objects KMS-encrypted.

## Why OpenTofu code instead of `aws s3api` commands?

A state bucket is not one CLI call — it's a bucket plus versioning,
encryption, public-access block, TLS policy, and lifecycle rules. As a
shell script that's a pile of imperative calls that are hard to make
idempotent and impossible to diff against reality. As OpenTofu code it's
declarative, reviewable, and `tofu plan` detects drift (someone disabling
versioning in the console shows up as a diff). Since every repo stamps
its own bucket from this template, the buckets stay uniform, and
hardening improvements to the template can be rolled out with a plan and
apply per repo rather than by hand.

## Why migrate the state into the bucket it created?

The alternative is leaving the bootstrap state local (or committing it to
git). That's worse on every axis that matters:

- A local state file lives on one laptop; when that laptop is gone, so is
  the record that this config manages the bucket.
- Committed state means no locking, merge conflicts on a machine-written
  file, and a habit of putting state in git — state files in general can
  contain secrets, so the habit is dangerous even when this one doesn't.
- Migrated state gets everything the bucket exists to provide: locking,
  encryption, versioning, durability.

The circularity ("the state describing the bucket lives in the bucket")
sounds alarming but has small, well-mitigated failure modes:

- **`tofu destroy` could delete the bucket out from under its own
  state.** Blocked by `prevent_destroy`; you must edit the code to even
  attempt it.
- **If the state object is lost, the config no longer knows about the
  bucket.** Versioning makes loss unlikely, and recovery is trivial
  anyway: this config is a handful of resources on one bucket, and
  `tofu import` rebuilds the state in minutes. This is the key point —
  the blast radius of the circular dependency is one small, easily
  re-imported config, which is a good trade for never having stray local
  state.

This is the standard bootstrap pattern; `tofu init -migrate-state`
exists precisely for it.
