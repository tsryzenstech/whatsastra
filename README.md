# WhatsAstra

WhatsApp for astraOS, as a **native astraOS app**: built with the
[astraOS SDK](https://github.com/tsryzenstech/astra/blob/main/docs/sdk/README.md)
from the system's own components (Astra.Controls), so it looks and behaves like
the rest of the phone: light and dark mode, the user's text size, the system's
navigation and sheets. No web page in a frame.

- chats with search, archived chats, pinned chats, unread counts and profile photos
- conversations: text, photos, videos, voice messages, audio and documents
  (play, view, save to Files), replies, reactions, delete for everyone, read
  receipts, group senders, older messages as you scroll
- send text, replies and photos or videos from the phone
- start a chat with a phone number
- notifications for new messages, also with the app closed (one per chat)
- link with a QR code, unlink from Settings

## How it reaches WhatsApp

WhatsApp's protocol runs **on the phone**, in WhatsAstra's background service
(`service/`, Go): astraOS starts it with the phone, as WhatsAstra's own user,
and keeps it running (app.json `"services"`). It links the phone to your
WhatsApp as a companion device, like WhatsApp Web, through
[whatsmeow](https://github.com/tulir/whatsmeow) (MPL-2.0): messages are end
to end encrypted to the phone and pass through no other server. Chats and
messages are kept in the app's data, in SQLite
([modernc.org/sqlite](https://gitlab.com/cznic/sqlite), pure Go).

```
WhatsAstra (QML, Astra.Controls) <-> whatsastra-service (127.0.0.1, token) <-> WhatsApp
                                        \-> astrad: notifications
```

The service listens on 127.0.0.1 at the port and with the token it writes to
`files/service.json`, which only WhatsAstra's user can read (the API is listed
at the top of `service/main.go`). WhatsApp keeps no history for linked devices:
what the main phone sends right after linking, and everything since, is what
WhatsAstra shows.

**WhatsApp does not support this officially:** whatsmeow speaks WhatsApp's
protocol as reverse engineered by its authors, and WhatsApp can restrict or ban
an account linked this way. Use a number you can afford to lose.

WhatsAstra is not made by or affiliated with WhatsApp or Meta.

Before 3.0 the protocol ran on the astraOS server (astra-cloud and OpenWA):
that is no longer needed.

## Building and publishing

    python3 tools/build.py --astra ../astra

It needs [Go](https://go.dev) 1.24 or newer: it builds the service for the
phone (linux/arm64, static) into the app's `bin/`, then runs `astra build` from the SDK: the design language check, then the
package (`dist/com.astra.whatsastra.apkg`). Open `app/` in
[Astra Studio](https://github.com/tsryzenstech/astra-studio) to edit it with the
live preview.

GitHub Actions builds a release on every change; with the `ASTRA_CLOUD_TOKEN`
secret it is also uploaded to Market. astra-cloud also ships it as a default app
from its `seed/` folder.

## License

GPL-3.0-or-later.
