# WhatsAstra

WhatsApp for astraOS, as a **native astraOS app**: built with the
[astraOS SDK](https://github.com/tsryzenstech/astra/blob/main/docs/sdk/README.md)
from the system's own components (Astra.Controls), so it looks and behaves like
the rest of the phone: light and dark mode, the user's text size, the system's
navigation and sheets. No web page in a frame.

- chats with search, unread counts and the last message
- conversations: send and receive messages, read receipts
- notifications for new messages
- link with a QR code, unlink from Settings

## How it reaches WhatsApp

WhatsApp has no official API for personal accounts. WhatsApp's protocol runs on
your astraOS server, in [OpenWA](https://github.com/rmyndharis/OpenWA) (MIT), next
to [astra-cloud](https://github.com/tsryzenstech/astra-cloud), which gives each
AstraID account its own WhatsApp session (`/api/app/com.astra.whatsastra/*`). The
app calls it through astraOS (`Account.request`), signed in with the phone's
AstraID: OpenWA is never exposed, and the app never sees a password or a key.

```
WhatsAstra (QML, Astra.Controls) -> astrad (AstraID token) -> astra-cloud -> OpenWA -> WhatsApp
```

**WhatsApp does not support this officially:** OpenWA uses reverse-engineered
clients, and WhatsApp can restrict or ban an account linked this way. Use a
number you can afford to lose. Messages pass through your server between
WhatsApp's encryption and the phone: host it yourself.

WhatsAstra is not made by or affiliated with WhatsApp or Meta.

## Building and publishing

    python3 tools/build.py --astra ../astra

The build runs `astra build` from the SDK: the design language check, then the
package (`dist/com.astra.whatsastra.apkg`). Open `app/` in
[Astra Studio](https://github.com/tsryzenstech/astra-studio) to edit it with the
live preview.

GitHub Actions builds a release on every change; with the `ASTRA_CLOUD_TOKEN`
secret it is also uploaded to Market. astra-cloud also ships it as a default app
from its `seed/` folder.

## License

GPL-3.0-or-later.
