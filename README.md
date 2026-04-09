# Suvadu Cloud Deploy

Deploy Suvadu — your AI memory service — to your own Google Cloud account.

## Quick Start

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/aisforapp/suvadu-deploy.git&cloudshell_tutorial=tutorial.md&cloudshell_working_dir=suvadu-deploy)

Or manually:

```bash
git clone https://github.com/aisforapp/suvadu-deploy.git
cd suvadu-deploy
bash deploy.sh
```

## What It Does

The deploy script provisions in **your** Google Cloud account:

1. Creates a GCP project for your Suvadu data
2. Sets up Cloud Storage for your memories
3. Deploys Suvadu to Cloud Run
4. Prints your endpoint URL

**Time**: ~3 minutes
**GCP cost**: Low — typically free for personal use under GCP's free tier

## Requirements

- A Suvadu Pro license key (`SVPRO-...`)
- A Google Cloud account with billing enabled (free trial works — $300 credit)

## Cleanup

To remove everything:

```bash
bash cleanup.sh
```

## Links

- **Website**: [suvadu.aisforapp.com](https://suvadu.aisforapp.com)
- **Install Suvadu locally**: [suvadu.aisforapp.com/install](https://suvadu.aisforapp.com/install)
- **Support**: hello@aisforapp.com
