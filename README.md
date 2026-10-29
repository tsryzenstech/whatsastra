# WhatsAstra

WhatsApp for astraOS, on top of WhatsApp Web (QtWebEngine): link it from your
main phone (WhatsApp › Linked devices) by scanning the QR code.

- notifications with the unread count, sounds through the system
- attachments from your storage, downloads to Files › Download
- share photos, videos and text to WhatsAstra from other apps
- zoom to fit the phone, spell check, dark mode from WhatsApp's settings
- links open in Planet

Its feature set is inspired by [Whatsie](https://github.com/keshavbhatt/whatsie)
(GPL-3.0), a Qt desktop client for WhatsApp Web; WhatsAstra is written from
scratch in QML for astraOS and is distributed under the same license.

WhatsAstra is not made by or affiliated with WhatsApp or Meta.

## Building and publishing

    python3 tools/build.py --astra ../astra

GitHub Actions builds a release on every change; with the `ASTRA_CLOUD_TOKEN`
secret it is also uploaded to Market. The astra cloud server also ships it as a
default app from its `seed/` folder.
