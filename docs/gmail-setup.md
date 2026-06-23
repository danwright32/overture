# Gmail setup (one time, by Dan)

Overture sends approved emails through your real photography Gmail
(dan@danwrightphotography.com) using the Gmail API with OAuth. This is the one part
only you can do. **Doing this setup sends nothing** — it only grants the app
permission to send later, and only ever when you click Send.

You'll create a Google Cloud project and an OAuth credential, then hand the app the
Client ID and Client Secret.

## Steps (Google Cloud Console)

1. Go to https://console.cloud.google.com and sign in as dan@danwrightphotography.com.
2. Create a project: top bar project dropdown → New Project → name it "Overture" → Create.
   Make sure the new project is selected.
3. Enable the Gmail API: ☰ → APIs & Services → Library → search "Gmail API" → Enable.
4. OAuth consent screen: APIs & Services → OAuth consent screen.
   - User Type: **Internal** (available because it's a Workspace account; no Google
     review needed) → Create.
   - App name "Overture", user support email = your address, developer contact =
     your address → Save and Continue.
   - Scopes → Add or Remove Scopes → add these two, then Update:
     - `https://www.googleapis.com/auth/gmail.send` (send mail)
     - `https://www.googleapis.com/auth/gmail.readonly` (detect replies)
   - Save and Continue to the end.
5. Create the credential: APIs & Services → Credentials → Create Credentials →
   OAuth client ID.
   - Application type: **Desktop app**.
   - Name: "Overture Desktop" → Create.
   - A dialog shows the **Client ID** and **Client secret**. Download the JSON too.

## Hand it to the app

Tell me the Client ID and Client Secret (or save the downloaded JSON), and I'll store
them in your Mac Keychain and wire the login. For a desktop app these are not true
secrets (the flow also uses PKCE), but keep the JSON out of git regardless.

## What happens after

- The first time you click Send, the app opens a Google consent page in your browser
  once. You approve, and the app keeps a refresh token in the Keychain so you won't be
  asked again.
- Nothing sends during setup or login. Sending only happens when you click Send on
  approved drafts, and even then it's paced (throttled) so a batch never bursts.
