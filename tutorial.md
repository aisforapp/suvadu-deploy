# Deploy Suvadu Cloud

## What you're about to do

You'll deploy Suvadu — your AI memory service — to your own Google Cloud account.

**Time**: ~3 minutes
**GCP cost**: Low — typically free for personal use under GCP's free tier. You pay Google based on usage.
**What gets created**: A Cloud Run service + a storage bucket in YOUR Google Cloud

**You'll need:**
- A Suvadu Pro license key (starts with `SVPRO-`, check your email)
- A Google Cloud billing account (free trial works — $300 credit, no charge)

## Deploy

Run this command. It will ask for your license key:

```sh
bash deploy.sh
```

The script will:
1. Create a GCP project for your Suvadu data
2. Set up storage and security
3. Deploy Suvadu to Cloud Run
4. Print your endpoint URL

**This takes 2-3 minutes. Don't close this tab.**

## Copy your endpoint URL

When the script finishes, you'll see:

```
Your endpoint URL:
https://suvadu-mcp-xxx.run.app/mcp?token=sv_...
```

**Copy this URL.** You'll paste it into your AI tool settings.

## Connect Claude Desktop

1. Open **Claude Desktop**
2. Go to **Settings → MCP Servers**
3. Click **Add**
4. Paste your endpoint URL
5. Save

Claude will now use your cloud Suvadu for memory — across all your devices.

## Connect Claude on iPhone/iPad

1. Open the **Claude app** on your phone
2. Go to **Settings → MCP**
3. Tap **Add Server**
4. Paste your endpoint URL
5. Save

Your phone and desktop now share the same AI memory.

## You're done!

Your Suvadu Cloud is live.

- **GCP cost**: Low — typically free for personal use (you pay Google based on usage)
- **Your data**: In YOUR Google Cloud, not ours
- **Multi-device**: Same URL works everywhere — desktop, phone, tablet
- **To remove everything**: Run `bash cleanup.sh`

Questions? Email hello@aisforapp.com
