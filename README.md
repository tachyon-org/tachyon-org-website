# Tachyon Resilient Modeling — Project Website

Public website for the **Tachyon Resilient Modeling** project: methods, tools,
and open datasets for building computational models that stay accurate and
dependable under uncertainty, faults, and incomplete data.

The site is a dependency-free **static website** (plain HTML, one hand-written
CSS file, and a few lines of vanilla JavaScript) designed to be hosted cheaply
and reliably on **Amazon S3** static website hosting, optionally fronted by
**CloudFront**.

## Site Structure

| Page | File | Purpose |
| --- | --- | --- |
| Overview | `web/index.html` | Project description and research focus areas |
| Personnel | `web/personnel.html` | Investigators, researchers, students, collaborators |
| Publications | `web/publications.html` | Papers, preprints, and technical reports |
| Tools, Data Sets & Source Code | `web/tools.html` | Released software, datasets, and repositories |
| About | `web/about.html` | Site technology, dependencies, hosting, license |
| Sitemap | `web/sitemap.html` | Structure of the site |
| Error | `web/error.html` | 404 page served by S3 |

## Repository Layout

```
.
├── README.md
├── LICENSE
├── web/                  # the static website (upload this directory)
│   ├── index.html
│   ├── personnel.html
│   ├── publications.html
│   ├── tools.html
│   ├── about.html
│   ├── sitemap.html
│   ├── error.html
│   ├── css/style.css
│   ├── js/main.js
│   └── assets/logo.svg
└── deploy/               # AWS deployment tooling
    ├── config.yaml       # deployment configuration
    ├── common.sh         # shared helpers (config + AWS wrappers)
    ├── setup-aws.sh      # one-time S3 bucket provisioning
    └── deploy-aws.sh     # upload the site to S3
```

## Editing the Site

The pages ship with **placeholder content** (people, publications, tools). Edit
the corresponding HTML files to fill in the project's real details. No build
step is required — open any file in `web/` directly in a browser to preview.

To preview the whole site locally with correct paths:

```bash
cd web
python3 -m http.server 8000
# then open http://localhost:8000
```

## Deploying to AWS

Deployment is driven by `deploy/config.yaml`, with every value overridable by an
environment variable or a command-line flag. **Priority order** (highest first):

> command-line flag → environment variable (`TACHYON_*`) → `config.yaml` → built-in default

### Prerequisites

- [AWS CLI v2](https://aws.amazon.com/cli/) installed and configured
  (`aws configure`)
- An AWS account with permission to create and write S3 buckets

### 1. Configure

Edit `deploy/config.yaml`:

```yaml
bucket: tachyon-resilient-modeling   # must be globally unique
region: us-west-2
profile: ""                          # AWS CLI named profile, or blank for default
source_dir: web
index_document: index.html
error_document: error.html
cloudfront_distribution_id: ""       # set to also invalidate CloudFront on deploy
```

### 2. Provision the bucket (one time)

```bash
./deploy/setup-aws.sh
```

This creates the bucket, enables static website hosting, and applies a
public-read policy. Re-running it is safe. Use `--no-public` if you plan to
serve the site privately through CloudFront with Origin Access Control.

### 3. Upload the site

```bash
./deploy/deploy-aws.sh            # sync web/ to S3 (removes stale files)
./deploy/deploy-aws.sh --dry-run  # preview changes without uploading
```

After a successful deploy the script prints the live S3 website endpoint, e.g.
`http://tachyon-resilient-modeling.s3-website-us-west-2.amazonaws.com`.

### Common overrides

```bash
# Deploy to a different bucket without editing the config
./deploy/deploy-aws.sh --bucket my-other-bucket --region us-east-1

# Use a named AWS profile via environment variable
TACHYON_PROFILE=tachyon ./deploy/deploy-aws.sh

# Provision and invalidate a CloudFront distribution
./deploy/deploy-aws.sh --distribution E1234567890ABC
```

Run any script with `--help` for the full list of options.

## HTTPS and Custom Domains

The S3 website endpoint is HTTP-only. For HTTPS and a custom domain, put a
**CloudFront** distribution in front of the bucket, request a certificate in
**AWS Certificate Manager**, and point your domain at the distribution with
**Route 53** (or your DNS provider). Set `cloudfront_distribution_id` in
`config.yaml` so deploys automatically invalidate the CDN cache.

## License

Released under the [MIT License](LICENSE).
